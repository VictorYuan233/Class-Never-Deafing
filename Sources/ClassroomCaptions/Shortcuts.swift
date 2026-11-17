import AppKit
import Carbon
import Combine

enum CaptionShortcutAction: UInt32, CaseIterable, Identifiable {
    case show = 1
    case hide = 2

    var id: UInt32 { rawValue }
    var title: String { self == .show ? "显示字幕窗" : "隐藏字幕窗" }
    var defaultsKey: String { self == .show ? "captionWindowShowShortcut" : "captionWindowHideShortcut" }
}

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

    @Published private(set) var combinations: [CaptionShortcutAction: CaptionKeyCombination] = [:]
    @Published private(set) var recording: CaptionShortcutAction?
    @Published private(set) var message: String?

    private let defaults: UserDefaults
    private var registrations: [CaptionShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var onPress: ((CaptionShortcutAction) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in CaptionShortcutAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey),
               let shortcut = try? PropertyListDecoder().decode(CaptionKeyCombination.self, from: data) {
                combinations[action] = shortcut
            }
        }
    }

    func start(onPress: @escaping (CaptionShortcutAction) -> Void) {
        self.onPress = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == CaptionShortcuts.signature,
                  let action = CaptionShortcutAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<CaptionShortcuts>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                if shortcuts.recording == nil, shortcuts.registrations[action] != nil {
                    shortcuts.onPress?(action)
                }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status == noErr {
            restoreRegistrations()
        } else {
            message = "无法启用全局快捷键（\(status)）。"
        }
    }

    func beginRecording(_ action: CaptionShortcutAction) {
        if recording == action {
            cancelRecording()
            return
        }
        stopMonitoring()
        unregisterAll()
        message = nil
        recording = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            self.record(event, for: action)
            return nil
        }
    }

    func clear(_ action: CaptionShortcutAction) {
        stopMonitoring()
        if let reference = registrations.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
        combinations.removeValue(forKey: action)
        defaults.removeObject(forKey: action.defaultsKey)
        message = nil
        restoreRegistrations()
    }

    func cancelRecording() {
        guard recording != nil else { return }
        stopMonitoring()
        message = nil
        restoreRegistrations()
    }

    func shutdown() {
        stopMonitoring()
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onPress = nil
    }

    private func record(_ event: NSEvent, for action: CaptionShortcutAction) {
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
        if combinations.contains(where: { $0.key != action && $0.value.matches(shortcut) }) {
            message = "显示和隐藏字幕窗需使用不同的快捷键。"
            return
        }
        guard register(shortcut, for: action) else { return }
        combinations[action] = shortcut
        if let data = try? PropertyListEncoder().encode(shortcut) {
            defaults.set(data, forKey: action.defaultsKey)
        }
        stopMonitoring()
        message = nil
        restoreRegistrations()
    }

    private func register(_ shortcut: CaptionKeyCombination, for action: CaptionShortcutAction) -> Bool {
        guard eventHandler != nil else {
            message = "全局快捷键服务未能启用。"
            return false
        }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr {
                message = "\(shortcut.display) 已被占用，请为「\(action.title)」选择其他快捷键。"
            } else {
                message = "无法启用「\(action.title)」快捷键（\(status)），请换一个组合。"
            }
            return false
        }
        registrations[action] = reference
        return true
    }

    private func restoreRegistrations() {
        for action in CaptionShortcutAction.allCases {
            if registrations[action] == nil, let shortcut = combinations[action] {
                _ = register(shortcut, for: action)
            }
        }
    }

    private func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
    }

    private func stopMonitoring() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        recording = nil
    }
}
