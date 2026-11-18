import AppKit
import SwiftUI

struct CaptionView: View {
    @ObservedObject var session: ClassroomSession
    @ObservedObject var preferences: Preferences
    @ObservedObject var titlebar: CaptionTitlebarLayout
    @StateObject private var scrollState = CaptionScrollState()
    let begin: () -> Void
    let togglePause: () -> Void
    let stop: () -> Void
    let stopAndSaveAs: () -> Void

    private var foreground: Color { preferences.panelForeground }
    private var originalColor: Color { preferences.originalTypography.color?.swiftUIColor ?? foreground.opacity(0.80) }
    private var translationColor: Color { preferences.translationTypography.color?.swiftUIColor ?? foreground }

    private var stateColor: Color {
        switch session.phase {
        case .idle: session.hasError ? .red : foreground.opacity(0.40)
        case .listening: .green
        case .pausing, .paused: .orange
        case .authorizing, .starting, .reconnecting, .stopping: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                toolbar(compact: false)
                toolbar(compact: true)
            }
            .padding(.leading, titlebar.leading)
            .padding(.trailing, 10)
            .frame(height: 24)
            .padding(.top, max(0, titlebar.centerFromTop - 12))
            .padding(.bottom, 4)
            Rectangle().fill(foreground.opacity(0.15)).frame(height: 1)
            if let notice = session.notice ?? (session.phase == .authorizing ? "正在准备开始，可点击停止取消。" : nil) {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .padding(.horizontal, 18)
                    .padding(.top, 7)
            }
            if session.captions.isEmpty && session.liveDrafts.unbound.isEmpty {
                Spacer(minLength: 0)
            } else {
                transcript
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .shadow(color: foreground == .white ? .black.opacity(0.76) : .clear, radius: 1.6, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: preferences.background).opacity(preferences.opacity))
        .ignoresSafeArea(.container, edges: .top)
    }

    private func toolbar(compact: Bool) -> some View {
        let paused = session.phase == .paused
        let buttonWidth: CGFloat = compact ? 22 : 26
        return HStack(spacing: compact ? 3 : 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .frame(minWidth: 10, minHeight: 18)
                .accessibilityLabel("录制状态")
                .accessibilityValue(session.status)
                .help(session.status)
            languageMenu("源语言", values: Language.sources, selection: $preferences.sourceID, compact: compact)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .accessibilityHidden(true)
            languageMenu("目标语言", values: Language.targets, selection: $preferences.targetID, compact: compact)
            Spacer(minLength: compact ? 2 : 6)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = session.recordingClock.display
                Text(elapsed)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .fixedSize()
                    .accessibilityLabel("录制时间")
                    .accessibilityValue(elapsed)
            }
            HStack(spacing: compact ? 2 : 4) {
                control("开始", "play.fill", width: buttonWidth, enabled: session.phase == .idle, action: begin)
                control(paused ? "继续" : "暂停", paused ? "play.fill" : "pause.fill",
                        width: buttonWidth, enabled: paused || session.phase == .listening, action: togglePause)
                control("停止", "stop.fill", width: buttonWidth,
                        enabled: session.phase != .idle && session.phase != .stopping, action: stop)
                toolbarButton("停止并另存为", width: buttonWidth, enabled: session.canStopAndSaveAs, action: stopAndSaveAs) {
                    ZStack {
                        Image(systemName: "stop.fill").font(.system(size: 16, weight: .medium))
                        Image(systemName: "folder")
                            .font(.system(size: 7, weight: .bold))
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                Button {
                    preferences.floating.toggle()
                } label: {
                    Image(systemName: preferences.floating ? "pin.fill" : "pin")
                        .frame(width: buttonWidth, height: 24)
                        .background(foreground.opacity(preferences.floating ? 0.24 : 0.10),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .accessibilityLabel("保持在最前")
                .accessibilityValue(preferences.floating ? "开启" : "关闭")
                .help(preferences.floating ? "关闭置顶" : "保持在最前")
            }
            .fixedSize()
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func control(_ title: String, _ icon: String, width: CGFloat, enabled: Bool, action: @escaping () -> Void) -> some View {
        toolbarButton(title, width: width, enabled: enabled, action: action) {
            Image(systemName: icon)
        }
    }

    private func toolbarButton<Icon: View>(_ title: String, width: CGFloat, enabled: Bool, action: @escaping () -> Void,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: width, height: 24)
                .background(foreground.opacity(enabled ? 0.17 : 0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.47)
        .accessibilityLabel(title)
        .help(title)
    }

    private func languageMenu(_ title: String, values: [Language], selection: Binding<String>, compact: Bool) -> some View {
        let language = values.first { $0.id == selection.wrappedValue } ?? values[0]
        let shortLabel = switch language {
        case .automatic: compact ? "自动" : language.label
        case .simplified: title == "源语言" ? "普通话" : (compact ? "简中" : "简体中文")
        case .traditional: compact ? "繁中" : "繁体中文"
        default: language.label
        }
        return Menu {
            Picker(title, selection: selection) {
                ForEach(values) { Text($0.label).tag($0.id) }
            }
        } label: {
            Text(shortLabel).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(language.label)
        .help(title)
    }

    private var originalFont: Font { preferences.originalTypography.font(defaultWeight: .regular) }
    private var translationFont: Font { preferences.translationTypography.font(defaultWeight: .medium) }

    private var blankLineHeight: CGFloat {
        let size = max(preferences.originalTypography.size, preferences.translationTypography.size)
        let font = NSFont.systemFont(ofSize: CGFloat(size))
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func liveOriginal(_ text: String) -> some View {
        Text(text)
            .font(originalFont)
            .foregroundStyle(originalColor)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("liveOriginal")
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 13) {
                            ForEach(Caption.visibleRows(session.captions, drafts: session.liveDrafts.bound)) { caption in
                                captionRow(caption)
                            }
                            ForEach(session.liveDrafts.unbound) { draft in
                                liveOriginal(draft.text)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        Color.clear.frame(height: blankLineHeight).id("latest")
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: CaptionScrollGeometry.self,
                                value: .init(height: geometry.size.height,
                                             bottom: geometry.frame(in: .named("captionViewport")).maxY)
                            )
                        }
                    }
                }
                .coordinateSpace(name: "captionViewport")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(CaptionScrollGeometry.self) { geometry in
                    if scrollState.follow.shouldScroll(geometry, viewport: viewport.size.height, lineHeight: blankLineHeight),
                       !scrollState.scheduled {
                        scrollState.scheduled = true
                        Task { @MainActor in
                            scrollState.scheduled = false
                            if scrollState.follow.isFollowing {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { scroll.scrollTo("latest", anchor: .bottom) }
                            }
                        }
                    }
                }
                .onDisappear { scrollState.follow = CaptionScrollFollow() }
            }
        }
    }

    private func captionRow(_ caption: Caption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.original.isEmpty ? "此段未能转写" : caption.original)
                .font(originalFont)
                .foregroundStyle(originalColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !caption.translation.isEmpty {
                Text(caption.translation)
                    .font(translationFont)
                    .foregroundStyle(translationColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if caption.translationFailed {
                Button("翻译未完成 · 重试") { session.retryTranslation(caption.id) }
                    .font(.system(size: 12, weight: .medium))
                    .overlay(alignment: .bottom) { Rectangle().frame(height: 1).opacity(0.45) }
            } else if caption.originalFinal && !caption.original.isEmpty {
                Text("正在翻译…")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private final class CaptionScrollState: ObservableObject {
    var follow = CaptionScrollFollow()
    var scheduled = false
}

private struct CaptionScrollGeometry: PreferenceKey {
    static let defaultValue = CaptionScrollFollow.Geometry()

    static func reduce(value: inout CaptionScrollFollow.Geometry, nextValue: () -> CaptionScrollFollow.Geometry) {
        value = nextValue()
    }
}

private extension CaptionTypography {
    func font(defaultWeight: Font.Weight) -> Font {
        let fontDesign: Font.Design = switch design {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        let font = Font.system(size: CGFloat(size), weight: bold ? .bold : defaultWeight, design: fontDesign)
        return italic ? font.italic() : font
    }
}

private extension CaptionRGB {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

@MainActor
final class APIKeySettings: ObservableObject {
    let role: APIRole
    @Published var entry = "" { didSet { clearTest() } }
    @Published private(set) var hasSavedKey = false
    @Published private(set) var keyError: String?
    @Published private(set) var testStatus = ""
    @Published private(set) var isTesting = false
    private var testTask: Task<Void, Never>?

    init(role: APIRole) {
        self.role = role
    }

    var hasEntry: Bool { !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var keyHelp: String { hasSavedKey ? "API Key 已加密保存。输入新 Key 可替换。" : "输入 API Key 后，可以先测试，再加密保存。" }

    func refresh() {
        do {
            hasSavedKey = try APIKeyStore.local.load(role) != nil
            keyError = nil
        } catch {
            hasSavedKey = true
            keyError = error.localizedDescription
        }
    }

    func savedConnection(_ preferences: Preferences) throws -> APIConnection {
        try APIKeyStore.local.connection(role, endpoint: preferences.endpoint(role))
    }

    func save(_ preferences: Preferences) {
        do {
            try APIKeyStore.local.save(entry, role: role, endpoint: preferences.endpoint(role))
            entry = ""
            refresh()
        } catch {
            keyError = error.localizedDescription
        }
    }

    func delete() {
        do {
            try APIKeyStore.local.delete(role)
            entry = ""
            refresh()
        } catch {
            keyError = error.localizedDescription
        }
    }

    func clearTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testStatus = ""
    }

    func test(_ preferences: Preferences) {
        clearTest()
        do {
            let connection = try hasEntry
                ? APIConnection(endpoint: preferences.endpoint(role), key: APIConnection.validateKey(entry))
                : savedConnection(preferences)
            let operation: () async throws -> String
            switch role {
            case .transcription:
                let service = try preferences.transcription(using: connection)
                operation = { try await APIProbe.transcription(service) }
            case .translation:
                let service = try preferences.translation(using: connection)
                let target = Language.target(preferences.targetID)
                operation = {
                    let sample = target == .english ? "我们开始上课。" : "The class is about to begin."
                    return try await TranslationAPI.shared.translate(sample, to: target, service: service, previous: nil) { _ in }
                }
            }
            isTesting = true
            testStatus = "正在请求 \(connection.endpoint.base.host ?? "API")…"
            testTask = Task {
                do {
                    let result = try await operation()
                    guard !Task.isCancelled else { return }
                    testStatus = "测试通过 · \(APIResponseError.clean(result, key: connection.key))"
                } catch {
                    guard !Task.isCancelled else { return }
                    testStatus = "测试失败 · \(APIResponseError.clean(error.localizedDescription, key: connection.key))"
                }
                isTesting = false
                testTask = nil
            }
        } catch {
            testStatus = "测试失败 · \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @StateObject private var help = SettingsHelp()
    @ObservedObject var preferences: Preferences
    @ObservedObject var transcriptionKey: APIKeySettings
    @ObservedObject var translationKey: APIKeySettings
    @ObservedObject var shortcuts: CaptionShortcuts
    let chooseExportFolder: () -> Void
    let revealDiagnostics: () -> Void
    let openGuide: () -> Void
    let openAbout: () -> Void

    var body: some View {
        Form {
            Section("课程语言") {
                Picker("源语言", selection: $preferences.sourceID) {
                    ForEach(Language.sources) { Text($0.label).tag($0.id) }
                }
                .settingsHelp("录制时可在字幕窗切换，下一段原文使用新的源语言。")
                Picker("目标语言", selection: $preferences.targetID) {
                    ForEach(Language.targets) { Text($0.label).tag($0.id) }
                }
                .settingsHelp("录制时可在字幕窗切换，之后提交翻译的段落使用新的目标语言。")
            }
            Section("音频输入") {
                Picker("输入源", selection: $preferences.audioInputID) {
                    ForEach(preferences.audioChoices) { Text($0.label).tag($0.id) }
                }
                .settingsHelp("下次开始录制时生效。系统声音需要 macOS 的屏幕与系统音频录制权限。")
            }
            Section("分句") {
                Slider(value: Binding(
                    get: { Double(preferences.segmentationLength.rawValue) },
                    set: { value in
                        if let length = SegmentationLength(rawValue: Int(value.rounded())) {
                            preferences.segmentationLength = length
                        }
                    }
                ), in: Double(SegmentationLength.short.rawValue)...Double(SegmentationLength.extended.rawValue), step: 1) {
                    Text("分句长短")
                } minimumValueLabel: {
                    Text("短")
                } maximumValueLabel: {
                    Text("长")
                }
                .accessibilityValue(preferences.segmentationLength.title)
                .settingsHelp("\(preferences.segmentationLength.detail)。下次开始转写时生效。")
            }
            Section("自动暂停") {
                Toggle("无声时自动暂停", isOn: $preferences.silencePauseEnabled)
                    .settingsHelp("达到无声时长后停止采音和计时，点击「继续」可接着转写。")
                Stepper("无声时长：\(preferences.silencePauseMinutes) 分钟", value: $preferences.silencePauseMinutes,
                        in: SilenceAutoPause.minutes)
                    .disabled(!preferences.silencePauseEnabled)
                    .settingsHelp("设置触发自动暂停前的无声时间。")
            }
            Section("保存") {
                Toggle("自动保存录音和字幕", isOn: $preferences.automaticSave)
                    .settingsHelp("设置在下次开始转写时生效。关闭后，仍可用「停止并另存为」手动保存。")
                LabeledContent("录音和字幕保留天数") {
                    TextField("录音和字幕保留天数", value: Binding(
                        get: { preferences.retentionDays },
                        set: { preferences.retentionDays = max(0, $0) }
                    ), format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 74)
                }
                .disabled(!preferences.automaticSave)
                .settingsHelp("0 表示无限期保留。每次自动保存后清理默认目录中过期的自动记录。")
                LabeledContent("默认保存目录") {
                    Text(((preferences.exportFolder ?? TextExport.automaticFolder).path as NSString).abbreviatingWithTildeInPath)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .settingsHelp("停止时自动将录音和字幕存到此目录。")
                HStack {
                    Spacer()
                    if preferences.exportFolder != nil {
                        Button("恢复默认目录") { preferences.exportFolder = nil }
                            .settingsHelp("恢复 App 自带的课堂记录目录。")
                    }
                    Button("选择文件夹…", action: chooseExportFolder)
                        .settingsHelp("选择录音和字幕的默认保存目录。")
                }
            }
            Section("字幕窗") {
                Toggle("始终置顶", isOn: $preferences.floating)
                    .settingsHelp("开启后，字幕窗会浮在其他普通窗口上方。")
                ColorPicker("背景颜色", selection: Binding(
                    get: { Color(nsColor: preferences.background) },
                    set: { preferences.background = NSColor($0) }
                ), supportsOpacity: false)
                .settingsHelp("更改字幕窗的背景颜色。")
                LabeledContent("背景不透明度") {
                    Slider(value: $preferences.opacity, in: 0...1)
                        .accessibilityLabel("背景不透明度")
                    Text(preferences.opacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 42)
                }
                .settingsHelp("向左调低可让字幕窗背景更透明。")
            }
            Section("原文字幕字体") {
                fontControls($preferences.originalTypography, colorLabel: "原文字体颜色")
            }
            Section("译文字幕字体") {
                fontControls($preferences.translationTypography, colorLabel: "译文字体颜色")
            }
            Section("转写") {
                TextField("转写 API 地址", text: $preferences.transcriptionAddress, prompt: Text(APIEndpoint.openAI.absoluteString))
                    .onChange(of: preferences.transcriptionAddress) { _, _ in transcriptionKey.clearTest() }
                    .settingsHelp("填服务商提供的 API 基础地址。留空使用 OpenAI，下次开始转写时生效。")
                LabeledContent("转写模型") {
                    DefaultChoicePicker(title: "转写模型", selection: $preferences.transcriptionModel,
                                        choices: TranscriptionModel.allCases, defaultChoice: TranscriptionModel.defaultChoice,
                                        label: \.label)
                        .fixedSize()
                }
                .onChange(of: preferences.transcriptionModel) { _, _ in transcriptionKey.clearTest() }
                .settingsHelp(TranscriptionModel.allCases.map { "\($0.label) · \($0.help)" }.joined(separator: "\n"))
                if preferences.transcriptionModel == .custom {
                    TextField("转写模型 ID", text: $preferences.customTranscriptionModelID, prompt: Text("例如 whisper-1"))
                        .onChange(of: preferences.customTranscriptionModelID) { _, _ in transcriptionKey.clearTest() }
                        .settingsHelp("输入服务商提供的音频转写模型 ID。")
                }
                apiControls(transcriptionKey)
            }
            Section("翻译") {
                TextField("翻译 API 地址", text: $preferences.translationAddress, prompt: Text(APIEndpoint.openAI.absoluteString))
                    .onChange(of: preferences.translationAddress) { _, _ in translationKey.clearTest() }
                    .settingsHelp("填服务商提供的 API 基础地址。留空使用 OpenAI，下次开始转写时生效。")
                LabeledContent("翻译接口") {
                    DefaultChoicePicker(title: "翻译接口", selection: $preferences.translationFormat,
                                        choices: TranslationProtocol.allCases, defaultChoice: TranslationProtocol.defaultChoice,
                                        label: \.title)
                        .fixedSize()
                }
                .onChange(of: preferences.translationFormat) { _, _ in translationKey.clearTest() }
                .settingsHelp(TranslationProtocol.help)
                LabeledContent("翻译模型") {
                    DefaultChoicePicker(title: "翻译模型", selection: $preferences.translationModel,
                                        choices: TranslationModel.allCases, defaultChoice: TranslationModel.defaultChoice,
                                        label: \.label)
                        .fixedSize()
                }
                .onChange(of: preferences.translationModel) { _, _ in translationKey.clearTest() }
                .settingsHelp("选择生成译文的模型。服务商提供其他模型时，可选「自定义」。")
                if preferences.translationModel == .custom {
                    TextField("翻译模型 ID", text: $preferences.customTranslationModelID, prompt: Text("例如 gpt-6-luna"))
                        .onChange(of: preferences.customTranslationModelID) { _, _ in translationKey.clearTest() }
                        .settingsHelp("输入服务商提供的文本模型 ID，再点「测试翻译」。")
                }
                Toggle("翻译 Fast 模式", isOn: preferences.translationModel.allowsFast ? $preferences.fastTranslation : .constant(false))
                    .disabled(!preferences.translationModel.allowsFast)
                    .onChange(of: preferences.fastTranslation) { _, _ in translationKey.clearTest() }
                    .settingsHelp("开启时会请求 Fast。支持情况与费用取决于所选模型和服务商。")
                apiControls(translationKey)
            }
            Section("快捷键") {
                ForEach(CaptionShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            let isRecording = shortcuts.recording == action
                            let shortcut = shortcuts.combinations[action]
                            Button(isRecording ? "请按快捷键…" : shortcut?.display ?? "录制快捷键") {
                                shortcuts.beginRecording(action)
                            }
                            .accessibilityLabel("\(action.title)快捷键")
                            .accessibilityValue(isRecording ? "等待输入" : shortcut?.display ?? "未设置")
                            .settingsHelp(isRecording ? "按 Esc 可取消录制。" : "设定后可在其他 App 中使用。")
                            if shortcut != nil {
                                Button("清除") { shortcuts.clear(action) }
                                    .accessibilityLabel("清除\(action.title)快捷键")
                                    .settingsHelp("移除当前快捷键组合。")
                            }
                        }
                    }
                }
                if let message = shortcuts.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("诊断日志") {
                Toggle("记录诊断日志", isOn: $preferences.recordsDiagnostics)
                    .settingsHelp("关闭后停止记录，已保存的日志仍可查看。日志最多 1 MiB，超出后删除最早的记录。")
                Button("在 Finder 中显示日志", action: revealDiagnostics)
                    .settingsHelp("在 Finder 中定位诊断日志文件。")
            }
            Section {
                HStack {
                    Button("使用指南", action: openGuide)
                        .settingsHelp("查看字幕、模型和保存选项的使用说明。")
                    Button("关于", action: openAbout)
                        .settingsHelp("查看 App 版本、系统要求和本版更新。")
                }
            }
        }
        .formStyle(.grouped)
        .environmentObject(help)
        .onDisappear { help.dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in help.dismiss() }
        .onChange(of: preferences.targetID) { _, _ in translationKey.clearTest() }
        .onAppear {
            transcriptionKey.refresh()
            translationKey.refresh()
        }
    }

    @ViewBuilder
    private func apiControls(_ key: APIKeySettings) -> some View {
        SecureField("\(key.role.title) API Key", text: Binding(get: { key.entry }, set: { key.entry = $0 }),
                    prompt: Text(key.hasSavedKey ? "输入新 Key 以替换" : "粘贴 API Key"))
            .onSubmit { if key.hasEntry { key.save(preferences) } }
            .settingsHelp(key.keyHelp)
        if let error = key.keyError {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        HStack {
            if key.hasSavedKey {
                Button("删除\(key.role.title) Key", role: .destructive) { key.delete() }
                    .settingsHelp("清除这组设置在本机保存的 API Key。")
            }
            Spacer()
            Button("保存\(key.role.title) Key") { key.save(preferences) }
                .disabled(!key.hasEntry || key.isTesting)
                .settingsHelp("将 API Key 加密保存到本机。")
            Button(key.isTesting ? "取消测试" : "测试\(key.role.title)") {
                if key.isTesting { key.clearTest() } else { key.test(preferences) }
            }
            .settingsHelp(key.isTesting ? "取消本次测试请求。" : key.role == .transcription
                  ? "发送内置音频样例，测试可能计费。"
                  : "发送一句固定文本测试翻译，测试可能计费。")
        }
        if !key.testStatus.isEmpty {
            Text(key.testStatus)
                .font(.caption)
                .foregroundStyle(key.testStatus.hasPrefix("测试失败") ? Color.red : Color.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func fontControls(_ style: Binding<CaptionTypography>, colorLabel: String) -> some View {
        Picker("字体样式", selection: style.design) {
            ForEach(CaptionFontDesign.allCases) { Text($0.label).tag($0) }
        }
        .settingsHelp("选择字幕使用的字体样式。")
        Stepper(value: style.size, in: CaptionTypography.sizes) {
            LabeledContent("字号", value: "\(style.wrappedValue.size) pt")
        }
        .settingsHelp("增大或减小字幕字号。")
        Toggle("粗体", isOn: style.bold)
            .settingsHelp("用粗体显示字幕。")
        Toggle("斜体", isOn: style.italic)
            .settingsHelp("用斜体显示字幕。")
        ColorPicker(colorLabel, selection: Binding(
            get: { style.wrappedValue.color?.swiftUIColor ?? preferences.panelForeground },
            set: { input in
                if let rgb = NSColor(input).usingColorSpace(.sRGB) {
                    style.wrappedValue.color = CaptionRGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                }
            }
        ), supportsOpacity: false)
        .settingsHelp("为这组字幕指定文字颜色。")
        if style.wrappedValue.color != nil {
            Button("恢复自动颜色") { style.wrappedValue.color = nil }
                .settingsHelp("根据字幕窗背景自动选择易读的文字颜色。")
        }
    }

}
