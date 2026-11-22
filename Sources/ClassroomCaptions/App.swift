import AppKit
import Combine
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum AppMetadata {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Class Never Deafing"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    static let minimumSystem = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0"

    static var releaseHighlights: [String] {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let notes = try? PropertyListDecoder().decode(ReleaseNotes.self, from: data),
              notes.version == version else { return [] }
        return notes.highlights
    }

    private struct ReleaseNotes: Decodable {
        let version: String
        let highlights: [String]
    }
}

@main
struct ClassroomCaptionsApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        let menu = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu(title: AppMetadata.name)
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(AppController.openSettings), keyEquivalent: ",")
        settings.target = delegate
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(AppMetadata.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        menu.addItem(root)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        application.mainMenu = menu
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class Preferences: ObservableObject {
    struct AudioChoice: Identifiable {
        let id: String
        let label: String
    }

    @Published var sourceID = UserDefaults.standard.string(forKey: "captionSource") ?? Language.automatic.id {
        didSet { UserDefaults.standard.set(sourceID, forKey: "captionSource") }
    }
    @Published var targetID = UserDefaults.standard.string(forKey: "captionTarget") ?? Language.simplified.id {
        didSet { UserDefaults.standard.set(targetID, forKey: "captionTarget") }
    }
    @Published var audioInputID = UserDefaults.standard.string(forKey: "audioInputID") ?? AudioInput.defaultID {
        didSet { UserDefaults.standard.set(audioInputID, forKey: "audioInputID") }
    }
    @Published var segmentationLength = (UserDefaults.standard.object(forKey: "segmentationLength") as? Int)
        .flatMap(SegmentationLength.init(rawValue:)) ?? .standard {
        didSet { UserDefaults.standard.set(segmentationLength.rawValue, forKey: "segmentationLength") }
    }
    @Published var silencePauseEnabled = UserDefaults.standard.bool(forKey: "silencePauseEnabled") {
        didSet { UserDefaults.standard.set(silencePauseEnabled, forKey: "silencePauseEnabled") }
    }
    @Published var silencePauseMinutes = {
        let minutes = UserDefaults.standard.object(forKey: "silencePauseMinutes") as? Int ?? SilenceAutoPause.defaultMinutes
        return min(max(minutes, SilenceAutoPause.minutes.lowerBound), SilenceAutoPause.minutes.upperBound)
    }() {
        didSet { UserDefaults.standard.set(silencePauseMinutes, forKey: "silencePauseMinutes") }
    }
    @Published var exportFolder: URL? = {
        guard let path = UserDefaults.standard.string(forKey: "exportFolderPath") else { return nil }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        guard (try? PrivateDataLocation.check(folder)) != nil else { return nil }
        return folder
    }() {
        didSet { UserDefaults.standard.set(exportFolder?.path, forKey: "exportFolderPath") }
    }
    @Published var automaticSave = UserDefaults.standard.object(forKey: "automaticSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticSave, forKey: "automaticSave") }
    }
    @Published var retentionDays = max(0, UserDefaults.standard.integer(forKey: "retentionDays")) {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }
    @Published private(set) var audioInputs: [AudioInput] = []
    var audioChoices: [AudioChoice] {
        var choices = [
            AudioChoice(id: AudioInput.defaultID, label: "系统默认麦克风"),
            AudioChoice(id: AudioInput.systemID, label: "系统声音（扬声器／耳机输出）"),
        ]
        choices += audioInputs.map { AudioChoice(id: $0.id, label: $0.name) }
        if !choices.contains(where: { $0.id == audioInputID }) {
            choices.append(AudioChoice(id: audioInputID, label: "所选麦克风未连接"))
        }
        return choices
    }
    @Published var originalTypography = Preferences.loadTypography("originalTypography", fallback: .original) {
        didSet { saveTypography(originalTypography, key: "originalTypography") }
    }
    @Published var translationTypography = Preferences.loadTypography("translationTypography", fallback: .translation) {
        didSet { saveTypography(translationTypography, key: "translationTypography") }
    }

    func refreshAudioInputs() {
        audioInputs = AudioInput.devices()
    }

    private static func loadTypography(_ key: String, fallback: CaptionTypography) -> CaptionTypography {
        guard let data = UserDefaults.standard.data(forKey: key),
              var value = try? JSONDecoder().decode(CaptionTypography.self, from: data) else { return fallback }
        value.size = min(max(value.size, CaptionTypography.sizes.lowerBound), CaptionTypography.sizes.upperBound)
        return value
    }

    private func saveTypography(_ value: CaptionTypography, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    @Published var transcriptionModel = UserDefaults.standard.string(forKey: "transcriptionModel")
        .flatMap(TranscriptionModel.init(rawValue:)) ?? TranscriptionModel.defaultChoice {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel") }
    }
    @Published var transcriptionAddress = UserDefaults.standard.string(forKey: "transcriptionAddress") ?? "" {
        didSet { UserDefaults.standard.set(transcriptionAddress, forKey: "transcriptionAddress") }
    }
    @Published var translationAddress = UserDefaults.standard.string(forKey: "translationAddress") ?? "" {
        didSet { UserDefaults.standard.set(translationAddress, forKey: "translationAddress") }
    }
    @Published var customTranscriptionModelID = UserDefaults.standard.string(forKey: "customTranscriptionModelID") ?? "" {
        didSet { UserDefaults.standard.set(customTranscriptionModelID, forKey: "customTranscriptionModelID") }
    }
    @Published var translationFormat = UserDefaults.standard.string(forKey: "translationFormat")
        .flatMap(TranslationProtocol.init(rawValue:)) ?? TranslationProtocol.defaultChoice {
        didSet { UserDefaults.standard.set(translationFormat.rawValue, forKey: "translationFormat") }
    }
    @Published var translationModel = UserDefaults.standard.string(forKey: "translationModel")
        .flatMap(TranslationModel.init(rawValue:)) ?? TranslationModel.defaultChoice {
        didSet { UserDefaults.standard.set(translationModel.rawValue, forKey: "translationModel") }
    }
    @Published var customTranslationModelID = UserDefaults.standard.string(forKey: "customTranslationModelID") ?? "" {
        didSet { UserDefaults.standard.set(customTranslationModelID, forKey: "customTranslationModelID") }
    }
    @Published var fastTranslation = UserDefaults.standard.object(forKey: "fastTranslation") as? Bool ?? false {
        didSet { UserDefaults.standard.set(fastTranslation, forKey: "fastTranslation") }
    }

    func endpoint(_ role: APIRole) throws -> APIEndpoint {
        try APIEndpoint(role == .transcription ? transcriptionAddress : translationAddress)
    }

    func transcription(using connection: APIConnection) throws -> TranscriptionService {
        try TranscriptionService(connection: connection, selection: transcriptionModel,
                                 modelID: transcriptionModel.modelID(customID: customTranscriptionModelID))
    }

    func translation(using connection: APIConnection) throws -> TranslationService {
        try TranslationService(connection: connection, format: translationFormat,
                               model: translationModel.configuration(customID: customTranslationModelID, fast: fastTranslation))
    }
    @Published var recordsDiagnostics = AppLog.isEnabled {
        didSet { AppLog.setEnabled(recordsDiagnostics) }
    }
    @Published var floating = UserDefaults.standard.object(forKey: "floating") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floating, forKey: "floating") }
    }
    @Published var opacity = UserDefaults.standard.object(forKey: "backgroundOpacity") as? Double ?? 0.88 {
        didSet { UserDefaults.standard.set(opacity, forKey: "backgroundOpacity") }
    }
    @Published var background = Preferences.savedColor() {
        didSet {
            if let color = background.usingColorSpace(.deviceRGB) {
                UserDefaults.standard.set([color.redComponent, color.greenComponent, color.blueComponent], forKey: "backgroundRGB")
            }
        }
    }

    var panelForeground: Color {
        let rgb = background.usingColorSpace(.deviceRGB) ?? .black
        let lightness = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return opacity > 0.65 && lightness > 0.61 ? .black : .white
    }

    private static func savedColor() -> NSColor {
        let rgb = UserDefaults.standard.array(forKey: "backgroundRGB") as? [Double] ?? [0.075, 0.10, 0.15]
        guard rgb.count == 3 else { return .black }
        return NSColor(deviceRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }
}

@MainActor
final class CaptionTitlebarLayout: ObservableObject {
    // macOS can temporarily replace the close button with a wider sharing control.
    private static let minimumLeading: CGFloat = 80
    @Published private(set) var centerFromTop: CGFloat = 16
    @Published private(set) var leading: CGFloat = minimumLeading

    func align(to closeButton: NSButton, in content: NSView) {
        let frame = content.convert(closeButton.bounds, from: closeButton)
        let bounds = content.bounds
        let center = content.isFlipped ? frame.midY - bounds.minY : bounds.maxY - frame.midY
        guard frame.width > 0, (0..<bounds.height).contains(center) else { return }
        let inset = max(Self.minimumLeading, frame.maxX - bounds.minX + 12)
        if abs(centerFromTop - center) > 0.5 { centerFromTop = center }
        if abs(leading - inset) > 0.5 { leading = inset }
    }
}

final class CaptionPanel: NSPanel {
    let toolbarLayout = CaptionTitlebarLayout()

    override var canBecomeKey: Bool { true }

    func alignToolbar() {
        guard let close = standardWindowButton(.closeButton), let contentView else { return }
        toolbarLayout.align(to: close, in: contentView)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSOpenSavePanelDelegate {
    let session = ClassroomSession()
    let preferences = Preferences()
    private let transcriptionKey = APIKeySettings(role: .transcription)
    private let translationKey = APIKeySettings(role: .translation)
    private let shortcuts = CaptionShortcuts()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var panel: CaptionPanel?
    private var settings: NSWindow?
    private var guideWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var audioDevicesListener: AudioObjectPropertyListenerBlock?
    private var waitingToQuit = false
    private var sessionSavePanel: NSSavePanel?
    private var exportingTranscript = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.translationForRetry = { [weak self] in
            guard let self else { throw CancellationError() }
            let service = try self.preferences.translation(using: self.translationKey.savedConnection(self.preferences))
            let approved = UserDefaults.standard.stringArray(forKey: "approvedAPIAddresses")?.last
            guard service.connection.endpoint.base.absoluteString == approved else {
                throw AppFailure.api("请开始新的转写并确认新的翻译地址，再向该服务发送字幕。", retryable: false)
            }
            return service
        }
        AppLog.launch(version: AppMetadata.version, build: AppMetadata.build)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: AppMetadata.name)
            button.toolTip = AppMetadata.name
            button.target = self
            button.action = #selector(showStatusMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu.autoenablesItems = false
        statusItem = item
        session.$phase.sink { [weak self] phase in
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: phase == .listening ? "captions.bubble.fill" : "captions.bubble",
                accessibilityDescription: AppMetadata.name
            )
        }.store(in: &subscriptions)
        preferences.$floating.sink { [weak self] enabled in
            self?.panel?.level = enabled ? .floating : .normal
        }.store(in: &subscriptions)
        preferences.$sourceID.sink { [weak self] id in
            self?.session.selectSource(.source(id))
        }.store(in: &subscriptions)
        preferences.$targetID.sink { [weak self] id in
            self?.session.selectTarget(.target(id))
        }.store(in: &subscriptions)
        preferences.$silencePauseEnabled.combineLatest(preferences.$silencePauseMinutes).sink { [weak self] enabled, minutes in
            self?.session.configureSilencePause(minutes: enabled ? minutes : nil)
        }.store(in: &subscriptions)
        preferences.$exportFolder.sink { [weak self] folder in
            self?.session.exportFolder = folder
        }.store(in: &subscriptions)
        observeAudioDevices()
        shortcuts.start { [weak self] action in
            switch action {
            case .show: self?.showPanel()
            case .hide: self?.hidePanel()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fitPanelOnScreen), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showPanel()
        AppLog.event("app.ready")
    }

    @objc private func showStatusMenu(_ button: NSStatusBarButton) {
        updateStatusMenu()
        let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        button.highlight(true)
        defer { button.highlight(false) }
        statusMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
    }

    private func observeAudioDevices() {
        let callback: AudioObjectPropertyListenerBlock = { [weak preferences] _, _ in
            Task { @MainActor in preferences?.refreshAudioInputs() }
        }
        var property = AudioInput.hardwareDevicesProperty
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, callback) == noErr {
            audioDevicesListener = callback
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.phase != .idle else { return .terminateNow }
        if !waitingToQuit {
            waitingToQuit = true
            if let picker = sessionSavePanel { picker.cancel(nil) }
            session.stop()
            Task {
                while session.phase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.discardSavedArchive()
        AppLog.event("app.quit")
        shortcuts.shutdown()
        if let audioDevicesListener {
            var property = AudioInput.hardwareDevicesProperty
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, audioDevicesListener)
        }
    }

    private func updateStatusMenu() {
        let menu = statusMenu
        preferences.refreshAudioInputs()
        menu.removeAllItems()
        menu.addItem(item("开始转写", #selector(begin), enabled: session.phase == .idle))
        let paused = session.phase == .paused
        menu.addItem(item(paused ? "继续转写" : "暂停转写", #selector(togglePause), enabled: paused || session.phase == .listening))
        menu.addItem(item("停止转写", #selector(stop), enabled: session.phase != .idle && session.phase != .stopping))
        menu.addItem(item("停止并另存为…", #selector(stopAndSaveAs), enabled: session.canStopAndSaveAs))
        menu.addItem(item("隐藏字幕窗", #selector(hidePanel), enabled: panel?.isVisible == true))
        menu.addItem(item("显示字幕窗", #selector(showPanel)))
        if !session.savedFiles.isEmpty {
            menu.addItem(item("在 Finder 中显示已保存文件", #selector(revealExport)))
        }
        let folderItem = item("打开保存文件夹", #selector(openExportFolder))
        folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folderItem)
        menu.addItem(item("另存本节课文本…", #selector(save), enabled: session.canExport))
        menu.addItem(item("查看本节课历史", #selector(showHistory), enabled: session.hasHistory))
        menu.addItem(.separator())
        menu.addItem(selectionMenu("输入源", values: preferences.audioChoices.map { ($0.id, $0.label) },
                                   chosen: preferences.audioInputID, action: #selector(pickAudioInput(_:))))
        menu.addItem(selectionMenu("源语言", values: Language.sources.map { ($0.id, $0.label) },
                                   chosen: preferences.sourceID, action: #selector(pickSource(_:))))
        menu.addItem(selectionMenu("目标语言", values: Language.targets.map { ($0.id, $0.label) },
                                   chosen: preferences.targetID, action: #selector(pickTarget(_:))))
        menu.addItem(.separator())
        let settingsItem = item("设置", #selector(openSettings))
        if #available(macOS 27.0, *) {
            settingsItem.preferredImageVisibility = .hidden
        } else if #available(macOS 26.0, *) {
            // An explicit empty image prevents AppKit from inferring a Settings icon.
            settingsItem.image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        }
        menu.addItem(settingsItem)
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func selectionMenu(_ title: String, values: [(id: String, label: String)], chosen: String, action: Selector) -> NSMenuItem {
        let selection = values.first { $0.id == chosen } ?? values.first
        let parent = NSMenuItem(title: selection.map { "\(title) · \($0.label)" } ?? title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for value in values {
            let entry = item(value.label, action)
            entry.representedObject = value.id
            entry.state = value.id == selection?.id ? .on : .off
            menu.addItem(entry)
        }
        parent.submenu = menu
        return parent
    }

    @objc private func pickAudioInput(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { preferences.audioInputID = id }
    }

    @objc private func pickSource(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { preferences.sourceID = id }
    }

    @objc private func pickTarget(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { preferences.targetID = id }
    }

    @objc func begin() {
        guard session.phase == .idle, !exportingTranscript else { return }
        showPanel()
        session.start(
            source: .source(preferences.sourceID), target: .target(preferences.targetID),
            audioInputID: preferences.audioInputID, segmentationLength: preferences.segmentationLength,
            automaticSave: preferences.automaticSave, retentionDays: preferences.retentionDays
        ) { [weak self] in
            try await self?.authorizeStart()
        }
    }

    private func authorizeStart() async throws -> SessionAPIs? {
        let apis: SessionAPIs
        do {
            let transcription = try preferences.transcription(using: transcriptionKey.savedConnection(preferences))
            let translation = try preferences.translation(using: translationKey.savedConnection(preferences))
            apis = SessionAPIs(transcription: transcription, translation: translation)
        } catch {
            openSettings()
            throw error
        }
        try Task.checkCancellation()
        let destinations = [apis.transcription.connection, apis.translation.connection].map { $0.endpoint.base.absoluteString }
        let defaults = UserDefaults.standard
        if defaults.stringArray(forKey: "approvedAPIAddresses") != destinations {
            AppLog.event("app.consent.prompt")
            let accepted = await requestCloudConsent(transcription: destinations[0], translation: destinations[1])
            try Task.checkCancellation()
            AppLog.event(accepted ? "app.consent.accepted" : "app.consent.declined")
            guard accepted else { return nil }
            defaults.set(destinations, forKey: "approvedAPIAddresses")
        }
        return apis
    }

    private func requestCloudConsent(transcription: String, translation: String) async -> Bool {
        guard let panel else { return false }
        let alert = NSAlert()
        alert.messageText = "使用音频输入和 API"
        alert.informativeText = "转写用音频将发送至 \(transcription)。待译原文将发送至 \(translation)。点击停止后，录音和双语字幕会自动保存在你设置的文件夹。"
        alert.addButton(withTitle: "同意并开始")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: panel) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        } onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent === panel {
                    panel.endSheet(alert.window, returnCode: .cancel)
                }
            }
        }
    }

    @objc private func stop() {
        session.stop()
    }

    @objc private func stopAndSaveAs() {
        guard session.canStopAndSaveAs else { return }
        session.stop { [weak self] suggestedName, error in
            guard let self, !self.waitingToQuit else { return nil }
            return await self.chooseSessionCopy(suggestedName: suggestedName, error: error)
        }
    }

    private func chooseSessionCopy(suggestedName: String, error: String?) async -> SessionExport? {
        let picker = NSSavePanel()
        picker.title = "停止并另存为"
        picker.prompt = "另存"
        picker.message = error.map { "未能另存，请选择其他文件名或文件夹。\n\($0)" }
            ?? "录音和字幕将使用同一名称。"
        picker.canCreateDirectories = true
        picker.delegate = self
        picker.directoryURL = preferences.exportFolder ?? TextExport.automaticFolder
        picker.nameFieldStringValue = suggestedName
        showPanel()
        NSApp.activate(ignoringOtherApps: true)
        guard let panel else { return nil }
        sessionSavePanel = picker
        return await withCheckedContinuation { continuation in
            picker.beginSheetModal(for: panel) { [weak self] response in
                self?.sessionSavePanel = nil
                continuation.resume(returning: response == .OK ? picker.url.map(SessionExport.init(savePanelURL:)) : nil)
            }
        }
    }

    @objc private func togglePause() {
        if session.phase == .paused { session.resume() } else { session.pause() }
    }

    @objc private func hidePanel() {
        panel?.orderOut(nil)
    }

    @objc private func showPanel() {
        if let panel {
            fitPanelOnScreen()
            panel.orderFrontRegardless()
            panel.alignToolbar()
            return
        }
        let panel = CaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = AppMetadata.name
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 160)
        panel.delegate = self
        panel.level = preferences.floating ? .floating : .normal
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: CaptionView(
            session: session,
            preferences: preferences,
            titlebar: panel.toolbarLayout,
            begin: { [weak self] in self?.begin() },
            togglePause: { [weak self] in self?.togglePause() },
            stop: { [weak self] in self?.stop() },
            stopAndSaveAs: { [weak self] in self?.stopAndSaveAs() }
        ))
        panel.center()
        panel.setFrameAutosaveName("ClassroomCaptionFrame")
        self.panel = panel
        fitPanelOnScreen()
        panel.orderFrontRegardless()
        panel.alignToolbar()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? CaptionPanel)?.alignToolbar()
    }

    func windowDidResignKey(_ notification: Notification) {
        if let settings, notification.object as? NSWindow === settings {
            shortcuts.cancelRecording()
        }
    }

    @objc private func fitPanelOnScreen() {
        guard let panel, let screen = NSScreen.main else { return }
        let valid = NSScreen.screens.contains { candidate in
            let intersection = candidate.visibleFrame.intersection(panel.frame)
            return intersection.width >= 120 && intersection.height >= 70
        }
        if !valid {
            let space = screen.visibleFrame
            let size = NSSize(width: min(panel.frame.width, space.width), height: min(panel.frame.height, space.height))
            let location = NSPoint(x: space.midX - size.width / 2, y: space.minY + 30)
            panel.setFrame(NSRect(origin: location, size: size), display: true)
        }
    }

    @objc fileprivate func openSettings() {
        preferences.refreshAudioInputs()
        if settings == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 490, height: 565),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "\(AppMetadata.name) 设置"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                preferences: preferences,
                transcriptionKey: transcriptionKey,
                translationKey: translationKey,
                shortcuts: shortcuts,
                chooseExportFolder: { [weak self] in self?.chooseExportFolder() },
                revealDiagnostics: { [weak self] in self?.revealDiagnostics() },
                openGuide: { [weak self] in self?.showGuide() },
                openAbout: { [weak self] in self?.showAbout() }
            ))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    private func revealDiagnostics() {
        Task {
            do {
                let url = try await AppLog.currentFile()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                showError(error)
            }
        }
    }

    @objc private func showGuide() {
        if guideWindow == nil {
            guard let url = Bundle.main.url(forResource: "使用指南", withExtension: "html") else {
                showError(CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "无法打开 App 内置的使用指南。"]))
                return
            }
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let page = WKWebView(frame: .zero, configuration: configuration)
            page.loadFileURL(url, allowingReadAccessTo: url)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "\(AppMetadata.name) 使用指南"
            window.minSize = NSSize(width: 440, height: 340)
            window.isReleasedWhenClosed = false
            window.contentView = page
            window.center()
            guideWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        let notes = AppMetadata.releaseHighlights.map { "• \($0)" }.joined(separator: "\n")
        let details = """
            实时双语字幕与课堂文本导出
            Apple Silicon · macOS \(AppMetadata.minimumSystem) 或更高版本

            本版更新
            \(notes)
            """
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppMetadata.name,
            .applicationVersion: AppMetadata.version,
            .version: AppMetadata.build,
            .credits: NSAttributedString(string: details, attributes: [.font: NSFont.systemFont(ofSize: 12)]),
        ])
    }

    private func chooseExportFolder() {
        guard let settings else { return }
        let picker = NSOpenPanel()
        picker.title = "选择字幕和录音保存文件夹"
        picker.prompt = "选择"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.directoryURL = preferences.exportFolder ?? FileManager.default.homeDirectoryForCurrentUser
        picker.beginSheetModal(for: settings) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            do {
                try PrivateDataLocation.check(url)
                self.preferences.exportFolder = url
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func revealExport() {
        NSWorkspace.shared.activateFileViewerSelecting(session.savedFiles)
    }

    @objc private func openExportFolder() {
        let folder = preferences.exportFolder ?? TextExport.automaticFolder
        do {
            try SessionExport.prepare(folder: folder, createFolder: preferences.exportFolder == nil)
            guard NSWorkspace.shared.open(folder) else { throw CocoaError(.fileReadUnknown) }
        } catch {
            showError(error)
        }
    }

    @objc private func save() {
        guard session.canExport, !exportingTranscript else { return }
        let historyID = session.historyID
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.plainText]
        dialog.canCreateDirectories = true
        dialog.delegate = self
        dialog.directoryURL = preferences.exportFolder ?? TextExport.automaticFolder
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd-HHmm"
        dialog.nameFieldStringValue = "课堂字幕-\(date.string(from: Date())).txt"
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        exportingTranscript = true
        let transcript = session.completeTranscript()
        Task {
            defer { exportingTranscript = false }
            do {
                let content = try await transcript.value
                try await Task.detached(priority: .utility) {
                    try PrivateDataLocation.check(url.deletingLastPathComponent())
                    try PrivateDataLocation.check(url)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }.value
                session.markTranscriptExported(historyID: historyID)
                let alert = NSAlert()
                alert.messageText = "课堂文本已保存"
                alert.informativeText = url.lastPathComponent
                alert.runModal()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func showHistory() {
        guard session.hasHistory else { return }
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "本节课历史"
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.contentView = NSHostingView(rootView: TranscriptHistoryView(session: session))
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try PrivateDataLocation.check(url.deletingLastPathComponent())
        try PrivateDataLocation.check(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
