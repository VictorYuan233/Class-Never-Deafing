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
        application.setActivationPolicy(.accessory)
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
    @Published var exportFolder = UserDefaults.standard.string(forKey: "exportFolderPath")
        .map { URL(filePath: $0, directoryHint: .isDirectory) } {
        didSet { UserDefaults.standard.set(exportFolder?.path, forKey: "exportFolderPath") }
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
        .flatMap(TranscriptionModel.init(rawValue:)) ?? .live {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel") }
    }
    @Published var translationModel = UserDefaults.standard.string(forKey: "translationModel")
        .flatMap(TranslationModel.init(rawValue:)) ?? .luna {
        didSet { UserDefaults.standard.set(translationModel.rawValue, forKey: "translationModel") }
    }
    @Published var customTranslationModelID = UserDefaults.standard.string(forKey: "customTranslationModelID") ?? "" {
        didSet { UserDefaults.standard.set(customTranslationModelID, forKey: "customTranslationModelID") }
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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = ClassroomSession()
    let preferences = Preferences()
    private let keySettings = KeySettings()
    private let shortcuts = CaptionShortcuts()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var panel: CaptionPanel?
    private var settings: NSWindow?
    private var guideWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var audioDevicesListener: AudioObjectPropertyListenerBlock?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
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
        menu.addItem(item("隐藏字幕窗", #selector(hidePanel), enabled: panel?.isVisible == true))
        menu.addItem(item("显示字幕窗", #selector(showPanel)))
        if session.automaticExportURL != nil {
            menu.addItem(item("在 Finder 中显示已保存字幕", #selector(revealExport)))
        }
        menu.addItem(item("另存本节课文本…", #selector(save), enabled: session.canExport))
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
        guard session.phase == .idle else { return }
        let translation: TranslationConfiguration
        do {
            translation = try preferences.translationModel.configuration(customID: preferences.customTranslationModelID)
        } catch {
            openSettings()
            showError(error)
            return
        }
        showPanel()
        session.start(
            source: .source(preferences.sourceID), target: .target(preferences.targetID),
            transcription: preferences.transcriptionModel, translation: translation,
            audioInputID: preferences.audioInputID
        ) { [weak self] in
            try await self?.authorizeStart()
        }
    }

    private func authorizeStart() async throws -> String? {
        let credential: String?
        if KeyStore.temporaryKey != nil { AppLog.event("keychain.read.temporary") }
        do {
            credential = try await KeyStore.read()
        } catch {
            if !Task.isCancelled {
                openSettings()
                keySettings.report(error)
            }
            throw error
        }
        try Task.checkCancellation()
        guard let credential else {
            openSettings()
            return nil
        }
        if !UserDefaults.standard.bool(forKey: "cloudDisclosureAccepted") {
            AppLog.event("app.consent.prompt")
            let accepted = await requestCloudConsent()
            try Task.checkCancellation()
            AppLog.event(accepted ? "app.consent.accepted" : "app.consent.declined")
            guard accepted else { return nil }
            UserDefaults.standard.set(true, forKey: "cloudDisclosureAccepted")
        }
        return credential
    }

    private func requestCloudConsent() async -> Bool {
        guard let panel else { return false }
        let alert = NSAlert()
        alert.messageText = "使用音频输入和 OpenAI"
        alert.informativeText = "开始后，App 会使用你设置的 API Key，把所选输入的音频及待翻译的课堂内容发送给 OpenAI。点击停止后，双语字幕会自动保存到你设置的文件夹。"
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
            revealExport: { [weak self] in self?.revealExport() }
        ))
        panel.center()
        panel.setFrameAutosaveName("ClassroomCaptionFrame")
        self.panel = panel
        fitPanelOnScreen()
        panel.orderFrontRegardless()
        panel.alignToolbar()
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

    @objc private func openSettings() {
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
                keys: keySettings,
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
        picker.title = "选择字幕保存文件夹"
        picker.prompt = "选择"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = preferences.exportFolder ?? FileManager.default.homeDirectoryForCurrentUser
        picker.beginSheetModal(for: settings) { [weak self] response in
            if response == .OK, let url = picker.url { self?.preferences.exportFolder = url }
        }
    }

    @objc private func revealExport() {
        if let url = session.automaticExportURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func save() {
        guard session.canExport else { return }
        let content = TextExport.render(session.captions)
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.plainText]
        dialog.canCreateDirectories = true
        dialog.directoryURL = preferences.exportFolder ?? TextExport.automaticFolder
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd-HHmm"
        dialog.nameFieldStringValue = "课堂字幕-\(date.string(from: Date())).txt"
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            let alert = NSAlert()
            alert.messageText = "课堂文本已保存"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
