import AppKit
import Carbon
import Combine

struct CaptionKeyCombination: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let usableModifiers: [(NSEvent.ModifierFlags, UInt32)] = [
            (.control, UInt32(controlKey)), (.option, UInt32(optionKey)),
            (.shift, UInt32(shiftKey)), (.command, UInt32(cmdKey)),
        ]
        let character = characters?.unicodeScalars.first
        let isFunctionKey = character.map { (0xF704...0xF717).contains($0.value) } ?? false
        guard !flags.intersection([.command, .control, .option]).isEmpty || isFunctionKey else { return nil }

        self.keyCode = UInt32(keyCode)
        modifiers = usableModifiers.reduce(0) { flags.contains($1.0) ? $0 | $1.1 : $0 }
        if isFunctionKey, let character {
            label = "F\(character.value - 0xF704 + 1)"
            return
        }
        switch Int(keyCode) {
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        case kVK_Return, kVK_ANSI_KeypadEnter: label = "↩"
        case kVK_Delete: label = "⌫"
        case kVK_ForwardDelete: label = "⌦"
        case kVK_Escape: label = "⎋"
        case kVK_Tab: label = "⇥"
        case kVK_Space: label = "空格"
        default:
            guard let character,
                  !CharacterSet.controlCharacters.contains(character),
                  !(0xF700...0xF8FF).contains(character.value) else { return nil }
            label = String(character).uppercased()
        }
    }

    var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.compactMap { (modifiers & UInt32($0.0)) != 0 ? $0.1 : nil }.joined() + label
    }

    func matches(_ other: CaptionKeyCombination) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

@MainActor
final class CaptionShortcuts: ObservableObject {
    nonisolated private static let signature: OSType = 0x434e4446
    nonisolated private static let hotKeyID: UInt32 = 1
    private static let defaultsKey = "captionWindowToggleShortcut"
    private static let legacyKeys = ["captionWindowShowShortcut", "captionWindowHideShortcut"]

    @Published private(set) var combination: CaptionKeyCombination?
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?

    private let defaults: UserDefaults
    private var registration: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var onPress: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = PropertyListDecoder()
        for key in [Self.defaultsKey] + Self.legacyKeys {
            guard let data = defaults.data(forKey: key),
                  let shortcut = try? decoder.decode(CaptionKeyCombination.self, from: data) else { continue }
            combination = shortcut
            if key != Self.defaultsKey { defaults.set(data, forKey: Self.defaultsKey) }
            break
        }
    }

    func start(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == CaptionShortcuts.signature,
                  id.id == CaptionShortcuts.hotKeyID else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<CaptionShortcuts>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                if !shortcuts.isRecording, shortcuts.registration != nil {
                    shortcuts.onPress?()
                }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status == noErr {
            restoreRegistration()
        } else {
            message = "无法启用全局快捷键（\(status)）。"
        }
    }

    func beginRecording() {
        if isRecording {
            cancelRecording()
            return
        }
        unregister()
        message = nil
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.record(event)
            return nil
        }
    }

    func clear() {
        stopMonitoring()
        unregister()
        combination = nil
        for key in [Self.defaultsKey] + Self.legacyKeys {
            defaults.removeObject(forKey: key)
        }
        message = nil
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopMonitoring()
        message = nil
        restoreRegistration()
    }

    func shutdown() {
        stopMonitoring()
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onPress = nil
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            cancelRecording()
            return
        }
        guard let shortcut = CaptionKeyCombination(keyCode: event.keyCode, flags: flags,
                                                   characters: event.charactersIgnoringModifiers) else {
            message = "请按带有 ⌘、⌥ 或 ⌃ 的组合键，或按一个功能键。"
            return
        }
        guard register(shortcut) else { return }
        combination = shortcut
        if let data = try? PropertyListEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        stopMonitoring()
        message = nil
    }

    private func register(_ shortcut: CaptionKeyCombination) -> Bool {
        guard eventHandler != nil else {
            message = "全局快捷键服务未能启用。"
            return false
        }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr {
                message = "\(shortcut.display) 已被占用，请选择其他快捷键。"
            } else {
                message = "无法启用「显示／隐藏字幕窗」快捷键（\(status)），请换一个组合。"
            }
            return false
        }
        registration = reference
        return true
    }

    private func restoreRegistration() {
        if registration == nil, let combination {
            _ = register(combination)
        }
    }

    private func unregister() {
        if let registration {
            UnregisterEventHotKey(registration)
            self.registration = nil
        }
    }

    private func stopMonitoring() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecording = false
    }
}
