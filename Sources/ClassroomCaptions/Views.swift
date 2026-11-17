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
    let revealExport: () -> Void

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
            if session.captions.isEmpty && session.liveOriginal.isEmpty {
                Spacer(minLength: 0)
            } else {
                transcript
            }
            if !session.liveOriginal.isEmpty {
                liveOriginal
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
                if session.automaticExportURL != nil {
                    Button(action: revealExport) {
                        Image(systemName: "folder").frame(width: buttonWidth, height: 24)
                    }
                    .accessibilityLabel("在 Finder 中显示已保存字幕")
                    .help("显示已保存的文件")
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
        Button(action: action) {
            Image(systemName: icon)
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

    private var liveOriginal: some View {
        Text(session.liveOriginal)
            .font(originalFont)
            .foregroundStyle(originalColor)
            .lineLimit(3)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 5)
            .padding(.bottom, blankLineHeight)
            .layoutPriority(1)
            .accessibilityIdentifier("liveOriginal")
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 13) {
                            ForEach(session.captions) { caption in
                                if !caption.original.isEmpty || caption.originalFailed {
                                    captionRow(caption)
                                }
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
final class KeySettings: ObservableObject {
    @Published var entry = ""
    @Published private(set) var hasSavedKey = false
    @Published private(set) var usesTemporaryKey = false
    @Published private(set) var keyStatus = ""
    @Published private(set) var isWorking = false

    var isConfigured: Bool { usesTemporaryKey || hasSavedKey }
    var hasEntry: Bool { !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func refreshSavedStatus() async {
        do {
            hasSavedKey = try await KeyStore.hasSavedKey()
        } catch {
            if !Task.isCancelled, !usesTemporaryKey, keyStatus.isEmpty { report(error) }
        }
    }

    func saveKey() {
        guard !isWorking, let key = validatedEntry() else { return }
        isWorking = true
        keyStatus = "正在等待钥匙串保存…"
        Task {
            defer { isWorking = false }
            do {
                try await KeyStore.save(key)
                hasSavedKey = true
                usesTemporaryKey = KeyStore.temporaryKey != nil
                if entry.trimmingCharacters(in: .whitespacesAndNewlines) == key { entry = "" }
                keyStatus = ""
            } catch {
                report(error)
            }
        }
    }

    func useTemporaryKey() {
        guard let key = validatedEntry() else { return }
        KeyStore.useUntilQuit(key)
        usesTemporaryKey = true
        entry = ""
        keyStatus = ""
    }

    func deleteKey() {
        if usesTemporaryKey {
            KeyStore.clearTemporaryKey()
            usesTemporaryKey = false
            entry = ""
            keyStatus = ""
            Task { await refreshSavedStatus() }
            return
        }
        guard !isWorking else { return }
        isWorking = true
        keyStatus = "正在等待钥匙串删除…"
        Task {
            defer { isWorking = false }
            do {
                try await KeyStore.delete()
                hasSavedKey = false
                keyStatus = ""
            } catch {
                report(error)
            }
        }
    }

    func report(_ error: Error) {
        keyStatus = error.localizedDescription
    }

    private func validatedEntry() -> String? {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        guard !key.contains(where: \.isWhitespace) else {
            keyStatus = "API Key 内不能包含空格或换行。"
            return nil
        }
        return key
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var keys: KeySettings
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
                Picker("目标语言", selection: $preferences.targetID) {
                    ForEach(Language.targets) { Text($0.label).tag($0.id) }
                }
                Text("录制时也可用字幕窗切换。源语言从下一段生效，目标语言用于接下来提交翻译的段落。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("音频输入") {
                Picker("输入源", selection: $preferences.audioInputID) {
                    ForEach(preferences.audioChoices) { Text($0.label).tag($0.id) }
                }
                Text("输入源在下次开始录制时生效。系统声音需要 macOS 的屏幕与系统音频录制权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("\(preferences.segmentationLength.detail)。下次开始转写时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("保存") {
                LabeledContent("默认保存目录") {
                    Text(((preferences.exportFolder ?? TextExport.automaticFolder).path as NSString).abbreviatingWithTildeInPath)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    if preferences.exportFolder != nil {
                        Button("恢复默认目录") { preferences.exportFolder = nil }
                    }
                    Button("选择文件夹…", action: chooseExportFolder)
                }
            }
            Section("字幕窗") {
                Toggle("始终置顶", isOn: $preferences.floating)
                ColorPicker("背景颜色", selection: Binding(
                    get: { Color(nsColor: preferences.background) },
                    set: { preferences.background = NSColor($0) }
                ), supportsOpacity: false)
                LabeledContent("背景不透明度") {
                    Slider(value: $preferences.opacity, in: 0...1)
                        .accessibilityLabel("背景不透明度")
                    Text(preferences.opacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 42)
                }
            }
            Section("原文字幕字体（如英文）") {
                fontControls($preferences.originalTypography, colorLabel: "原文字体颜色")
            }
            Section("译文字幕字体（如中文）") {
                fontControls($preferences.translationTypography, colorLabel: "译文字体颜色")
            }
            Section("模型") {
                Picker("转写模型", selection: $preferences.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases) { Text($0.label).tag($0) }
                }
                Picker("翻译模型", selection: $preferences.translationModel) {
                    ForEach(TranslationModel.allCases) { Text($0.label).tag($0) }
                }
                if preferences.translationModel == .custom {
                    TextField("OpenAI 模型 ID", text: $preferences.customTranslationModelID, prompt: Text("例如 gpt-6-luna"))
                    Text("请输入项目可用的 Responses API 模型 ID。开启 Fast 前请确认该模型支持 Fast。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("翻译 Fast 模式", isOn: preferences.translationModel.allowsFast ? $preferences.fastTranslation : .constant(false))
                    .disabled(!preferences.translationModel.allowsFast)
                Text(preferences.translationModel.allowsFast
                     ? "Fast 按 OpenAI 的加速费率计费。模型和 Fast 设置下次开始转写时生效。"
                     : "此预设仅使用项目默认处理方式。模型更改在下次开始转写时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            if shortcut != nil {
                                Button("清除") { shortcuts.clear(action) }
                                    .accessibilityLabel("清除\(action.title)快捷键")
                            }
                        }
                    }
                }
                if let message = shortcuts.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(shortcuts.recording == nil ? "设置后可在其他 App 中使用。" : "按 Esc 可取消录制。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("OpenAI API") {
                SecureField("API Key", text: $keys.entry, prompt: Text(keys.isConfigured ? "输入新 Key 以替换" : "粘贴你的 API Key"))
                    .onSubmit(keys.saveKey)
                if !keys.keyStatus.isEmpty {
                    Text(keys.keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if keys.usesTemporaryKey {
                    Text("正在使用临时 Key，退出 App 后清除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if keys.keyStatus.isEmpty {
                    Text(keys.hasSavedKey ? "已保存到钥匙串" : "尚未配置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if keys.isConfigured {
                        Button(keys.usesTemporaryKey ? "清除临时 Key" : "删除已保存 Key", role: .destructive, action: keys.deleteKey)
                            .disabled(keys.isWorking && !keys.usesTemporaryKey)
                    }
                    Spacer()
                    Button("仅本次使用", action: keys.useTemporaryKey)
                        .disabled(!keys.hasEntry)
                        .help("仅在 App 内存中保存，退出 App 后清除。")
                    Button("存入钥匙串", action: keys.saveKey)
                        .disabled(!keys.hasEntry || keys.isWorking)
                }
            }
            Section("诊断日志") {
                Toggle("记录诊断日志", isOn: $preferences.recordsDiagnostics)
                Button("在 Finder 中显示日志", action: revealDiagnostics)
                Text("关闭后停止记录，已保存的日志仍可查看。日志最多 1 MiB，超出后删除最早的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("使用指南", action: openGuide)
                    Button("详情", action: openAbout)
                }
            }
        }
        .formStyle(.grouped)
        .task { await keys.refreshSavedStatus() }
    }

    @ViewBuilder
    private func fontControls(_ style: Binding<CaptionTypography>, colorLabel: String) -> some View {
        Picker("字体样式", selection: style.design) {
            ForEach(CaptionFontDesign.allCases) { Text($0.label).tag($0) }
        }
        Stepper(value: style.size, in: CaptionTypography.sizes) {
            LabeledContent("字号", value: "\(style.wrappedValue.size) pt")
        }
        Toggle("粗体", isOn: style.bold)
        Toggle("斜体", isOn: style.italic)
        ColorPicker(colorLabel, selection: Binding(
            get: { style.wrappedValue.color?.swiftUIColor ?? preferences.panelForeground },
            set: { input in
                if let rgb = NSColor(input).usingColorSpace(.sRGB) {
                    style.wrappedValue.color = CaptionRGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                }
            }
        ), supportsOpacity: false)
        if style.wrappedValue.color != nil {
            Button("恢复自动颜色") { style.wrappedValue.color = nil }
        }
    }

}
