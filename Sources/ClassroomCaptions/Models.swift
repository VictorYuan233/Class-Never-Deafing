import Foundation

struct Language: Identifiable, Equatable {
    let id: String
    let label: String
    let instruction: String

    static let automatic = Language(id: "auto", label: "自动检测", instruction: "")
    static let simplified = Language(id: "zh-cn", label: "普通话（简体中文）", instruction: "Mandarin Chinese written in Simplified Chinese")
    static let traditional = Language(id: "zh-tw", label: "普通话（繁体中文）", instruction: "Mandarin Chinese written in Traditional Chinese")
    static let english = Language(id: "en", label: "英语", instruction: "English")
    static let cantonese = Language(id: "yue", label: "粤语", instruction: "Cantonese")
    static let other = [
        Language(id: "ja", label: "日语", instruction: "Japanese"),
        Language(id: "ko", label: "韩语", instruction: "Korean"),
        Language(id: "fr", label: "法语", instruction: "French"),
        Language(id: "es", label: "西班牙语", instruction: "Spanish"),
        Language(id: "de", label: "德语", instruction: "German"),
    ]
    static let sources = [automatic, english, simplified, cantonese] + other
    static let targets = [simplified, traditional, english] + other

    static func source(_ id: String) -> Language {
        sources.first { $0.id == id } ?? automatic
    }

    static func target(_ id: String) -> Language {
        targets.first { $0.id == id } ?? simplified
    }
}

struct Caption: Identifiable {
    let id = UUID()
    var recordingStartSeconds: Int64?
    var original = ""
    var translation = ""
    var originalFinal = false
    var translationFinal = false
    var originalFailed = false
    var translationFailed = false
    var translationLanguage = Language.simplified

    static func visibleRows(_ captions: [Caption], drafts: [UUID: String]) -> [Caption] {
        var lastRowWasFailure = false
        return captions.compactMap { caption in
            var row = caption
            if row.original.isEmpty, let text = drafts[row.id] { row.original = text }
            if !row.original.isEmpty {
                lastRowWasFailure = false
                return row
            }
            guard row.originalFailed, !lastRowWasFailure else { return nil }
            lastRowWasFailure = true
            return row
        }
    }
}

struct TranscriptDrafts {
    struct Draft: Identifiable, Equatable {
        let connection: UUID
        let item: String
        var text: String

        var id: String { "\(connection):\(item)" }
    }

    struct Snapshot: Equatable {
        var unbound: [Draft] = []
        var bound: [UUID: String] = [:]
    }

    private var unbound: [Draft] = []
    private var bound: [UUID: String] = [:]

    @discardableResult
    mutating func append(_ delta: String, connection: UUID, item: String) -> Bool {
        if let index = unbound.firstIndex(where: { $0.connection == connection && $0.item == item }) {
            unbound[index].text += delta
            return false
        }
        unbound.append(Draft(connection: connection, item: item, text: delta))
        return true
    }

    mutating func bind(connection: UUID, item: String, to segment: UUID) {
        guard let index = unbound.firstIndex(where: { $0.connection == connection && $0.item == item }) else { return }
        bound[segment] = unbound.remove(at: index).text
    }

    @discardableResult
    mutating func append(_ delta: String, to segment: UUID) -> Bool {
        let isFirst = bound[segment] == nil
        bound[segment, default: ""] += delta
        return isFirst
    }

    @discardableResult
    mutating func remove(_ segment: UUID) -> String? {
        bound.removeValue(forKey: segment)
    }

    mutating func remove(connection: UUID) {
        unbound.removeAll { $0.connection == connection }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            unbound: unbound.filter { $0.text.contains { !$0.isWhitespace } },
            bound: bound.filter { $0.value.contains { !$0.isWhitespace } }
        )
    }
}

enum SilenceAutoPause {
    static let minutes = 1...120
    static let defaultMinutes = 5
}

enum SegmentationLength: Int, CaseIterable {
    case short, standard, longer, long, extended

    struct Limits {
        let pauseFrames: Int
        let longTurnPauseFrames: Int
        let longTurnFrames: Int
        let maximumFrames: Int
    }

    var title: String {
        switch self {
        case .short: "短"
        case .standard: "标准"
        case .longer: "偏长"
        case .long: "长"
        case .extended: "最长"
        }
    }

    var limits: Limits {
        switch self {
        case .short: .init(pauseFrames: 30, longTurnPauseFrames: 16, longTurnFrames: 260, maximumFrames: 400)
        case .standard: .init(pauseFrames: 42, longTurnPauseFrames: 22, longTurnFrames: 400, maximumFrames: 600)
        case .longer: .init(pauseFrames: 55, longTurnPauseFrames: 28, longTurnFrames: 520, maximumFrames: 800)
        case .long: .init(pauseFrames: 70, longTurnPauseFrames: 34, longTurnFrames: 720, maximumFrames: 1100)
        case .extended: .init(pauseFrames: 75, longTurnPauseFrames: 75, longTurnFrames: 1500, maximumFrames: 1500)
        }
    }

    var detail: String {
        let timing = limits
        let pause = Double(timing.pauseFrames) / 50
        let maximum = timing.maximumFrames / 50
        return "\(title) · 停顿约 \(pause.formatted(.number.precision(.fractionLength(1...2)))) 秒 · 每段最长 \(maximum) 秒"
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case live = "gpt-live-transcribe"
    case committed = "gpt-transcribe"
    case custom
    static let defaultChoice: Self = .live

    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "GPT-Live-Transcribe"
        case .committed: "GPT-Transcribe"
        case .custom: "自定义"
        }
    }

    var help: String {
        switch self {
        case .live: "通过 Realtime 接口边听边显示原文。"
        case .committed: "通过 Realtime 接口，在每段音频提交后返回原文。"
        case .custom: "每段结束后通过服务商的 /audio/transcriptions 接口转写。"
        }
    }

    func modelID(customID: String) throws -> String {
        if self != .custom { return rawValue }
        let id = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AppFailure.modelName
        }
        return id
    }
}

enum TranslationModel: String, CaseIterable, Identifiable {
    case luna = "gpt-6-luna"
    case terra = "gpt-6.1-terra"
    case sol = "gpt-6.1-sol"
    case astra = "gpt-6-astra"
    case mini54 = "gpt-5.4-mini-2026-03-17"
    case mini41 = "gpt-4.1-mini"
    case custom
    static let defaultChoice: Self = .luna

    var id: String { rawValue }
    var label: String {
        switch self {
        case .luna: "GPT-6 Luna"
        case .terra: "GPT-6.1 Terra"
        case .sol: "GPT-6.1 Sol"
        case .astra: "GPT-6 Astra"
        case .mini54: "GPT-5.4 mini"
        case .mini41: "GPT-4.1 mini"
        case .custom: "自定义"
        }
    }

    var allowsFast: Bool {
        self != .mini54 && self != .mini41
    }

    func configuration(customID: String = "", fast: Bool = false) throws -> TranslationConfiguration {
        let serviceTier = fast && allowsFast ? "fast" : nil
        switch self {
        case .custom:
            let id = customID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw AppFailure.modelName
            }
            return TranslationConfiguration(id: id, reasoningEffort: nil, serviceTier: serviceTier)
        case .luna, .terra, .mini54:
            return TranslationConfiguration(id: rawValue, reasoningEffort: "none", serviceTier: serviceTier)
        case .sol, .astra:
            return TranslationConfiguration(id: rawValue, reasoningEffort: "low", serviceTier: serviceTier)
        case .mini41:
            return TranslationConfiguration(id: rawValue, reasoningEffort: nil, serviceTier: serviceTier)
        }
    }
}

struct TranslationConfiguration: Equatable {
    let id: String
    let reasoningEffort: String?
    let serviceTier: String?
}

enum CaptionFontDesign: String, CaseIterable, Codable, Identifiable {
    case standard, rounded, serif, monospaced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "系统默认"
        case .rounded: "圆体"
        case .serif: "衬线"
        case .monospaced: "等宽"
        }
    }
}

struct CaptionTypography: Codable, Equatable {
    static let sizes = 10...60
    static let original = CaptionTypography(size: 15)
    static let translation = CaptionTypography(size: 19)

    var size: Int
    var design = CaptionFontDesign.standard
    var bold = false
    var italic = false
    var color: CaptionRGB?
}

struct CaptionRGB: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

struct CaptionScrollFollow {
    struct Geometry: Equatable {
        var height: CGFloat = 0
        var bottom: CGFloat = 0
    }

    private(set) var isFollowing = true
    private var lastHeight: CGFloat?
    private var lastViewport: CGFloat?

    mutating func shouldScroll(_ geometry: Geometry, viewport: CGFloat, lineHeight: CGFloat) -> Bool {
        guard geometry.height > 0, viewport > 0 else { return false }
        let resized = lastHeight.map { abs($0 - geometry.height) > 0.5 } ?? true
        let viewportChanged = lastViewport.map { abs($0 - viewport) > 0.5 } ?? true
        lastHeight = geometry.height
        lastViewport = viewport
        let distance = geometry.bottom - viewport
        if !resized && !viewportChanged || distance <= lineHeight * 2 {
            isFollowing = distance <= lineHeight * 2
        }
        return isFollowing && (resized || viewportChanged) && distance > 0.5
    }
}

struct RecordingClock {
    private var previous: Duration = .zero
    private var startedAt: SuspendingClock.Instant?

    mutating func resume(at now: SuspendingClock.Instant = SuspendingClock().now) {
        if startedAt == nil { startedAt = now }
    }

    mutating func pause(at now: SuspendingClock.Instant = SuspendingClock().now) {
        previous = elapsed(at: now)
        startedAt = nil
    }

    func elapsed(at now: SuspendingClock.Instant = SuspendingClock().now) -> Duration {
        previous + (startedAt?.duration(to: now) ?? .zero)
    }

    var display: String {
        Self.format(seconds: elapsed().components.seconds)
    }

    static func format(seconds: Int64) -> String {
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct SessionExport {
    static let fileExtensions = ["mp3", "wav", "txt"]
    let folder: URL
    let createFolder: Bool
    let name: String

    static func name(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "课堂字幕-\(formatter.string(from: date))-\(UUID().uuidString.prefix(8))"
    }

    func url(endingIn fileExtension: String) throws -> URL {
        try Self.prepare(folder: folder, createFolder: createFolder)
        return fileURL(endingIn: fileExtension)
    }

    func fileURL(endingIn fileExtension: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    init(folder: URL, createFolder: Bool, name: String) {
        self.folder = folder
        self.createFolder = createFolder
        self.name = name
    }

    init(savePanelURL: URL) {
        let recognizedExtension = Self.fileExtensions.contains(savePanelURL.pathExtension.lowercased())
        self.init(folder: savePanelURL.deletingLastPathComponent(), createFolder: false,
                  name: (recognizedExtension ? savePanelURL.deletingPathExtension() : savePanelURL).lastPathComponent)
    }

    func checkAvailable() throws {
        try Self.prepare(folder: folder, createFolder: createFolder)
        for ext in Self.fileExtensions {
            let path = fileURL(endingIn: ext).path
            if (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path])
            }
        }
    }

    static func prepare(folder: URL, createFolder: Bool) throws {
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
    }
}

enum ExportArchive {
    static func saveCopy(text: String, audio: URL?, to destination: SessionExport) throws -> [URL] {
        guard audio != nil || !text.isEmpty else { return [] }
        try destination.checkAvailable()
        let manager = FileManager.default
        var saved: [URL] = []
        do {
            if let audio {
                let url = destination.fileURL(endingIn: audio.pathExtension)
                try manager.copyItem(at: audio, to: url)
                saved.append(url)
            }
            if !text.isEmpty {
                let url = destination.fileURL(endingIn: "txt")
                let draft = destination.folder.appending(path: ".\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: draft) }
                try Data(text.utf8).write(to: draft, options: .withoutOverwriting)
                try manager.moveItem(at: draft, to: url)
                saved.append(url)
            }
            return saved
        } catch {
            for url in saved { try? manager.removeItem(at: url) }
            throw error
        }
    }

    static func removeExpired(in folder: URL, after days: Int, now: Date = .now) throws {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let manager = FileManager.default
        let candidates = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles])
        var records: [String: [(URL, Date)]] = [:]
        for file in candidates where SessionExport.fileExtensions.contains(file.pathExtension) {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.range(of: #"^课堂字幕-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-[A-F0-9]{8}$"#,
                             options: .regularExpression) != nil,
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink == false, let modified = values.contentModificationDate else { continue }
            records[name, default: []].append((file, modified))
        }
        var failure: Error?
        for record in records.values where record.allSatisfy({ $0.1 < cutoff }) {
            for (file, _) in record {
                do { try manager.removeItem(at: file) }
                catch { failure = error }
            }
        }
        if let failure { throw failure }
    }
}

enum TextExport {
    static var automaticFolder: URL {
        URL.applicationSupportDirectory.appending(path: "课堂字幕/课堂记录", directoryHint: .isDirectory)
    }

    static func render(_ captions: [Caption]) -> String {
        let blocks = captions.compactMap { caption -> String? in
            let original = line(caption.original)
            guard caption.originalFinal, !original.isEmpty else { return nil }
            let translation = line(caption.translation)
            let target = caption.translationFinal && !translation.isEmpty ? translation : "[翻译未完成]"
            let timestamp = caption.recordingStartSeconds.map { "[\(RecordingClock.format(seconds: $0))] " } ?? ""
            return timestamp + original + "\n" + target
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    static func saveAutomatically(_ content: String, to destination: SessionExport) throws -> URL {
        let url = try destination.url(endingIn: "txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum AppFailure: LocalizedError {
    case microphone
    case microphoneDenied
    case inputUnavailable
    case systemAudio, systemAudioDenied, systemAudioInterrupted, audioFormat
    case audioOverload
    case timeout
    case modelName
    case api(String, retryable: Bool)

    var errorDescription: String? {
        switch self {
        case .microphone: "无法读取默认麦克风。请检查系统设置中的声音输入。"
        case .microphoneDenied: "请在系统设置「隐私与安全性 → 麦克风」中允许 Class Never Deafing 访问。"
        case .inputUnavailable: "所选麦克风不可用。请重新连接设备，或在设置中选择其他麦克风。"
        case .systemAudio: "无法采集系统声音，请停止后重试。"
        case .systemAudioDenied: "请在系统设置「隐私与安全性 → 屏幕与系统音频录制」中允许 Class Never Deafing 访问，必要时退出后重开 App。"
        case .systemAudioInterrupted: "系统声音采集已中断。"
        case .audioFormat: "无法转换所选输入设备的音频格式。"
        case .audioOverload: "音频处理或网络发送跟不上，部分音频未能转写。"
        case .timeout: "连接 OpenAI 超时。"
        case .modelName: "请输入完整的模型 ID，ID 中不能有空格或换行。"
        case .api(let message, _): message
        }
    }

    var diagnosticCode: String {
        switch self {
        case .microphone: "microphone_start_failed"
        case .microphoneDenied: "microphone_denied"
        case .inputUnavailable: "input_unavailable"
        case .systemAudio: "system_audio_start_failed"
        case .systemAudioDenied: "system_audio_denied"
        case .systemAudioInterrupted: "system_audio_interrupted"
        case .audioFormat: "audio_format"
        case .audioOverload: "audio_overload"
        case .timeout: "connection_timeout"
        case .modelName: "invalid_model_id"
        case .api(_, let retryable): "openai_error retryable=\(retryable)"
        }
    }

    var canRetry: Bool {
        switch self {
        case .timeout, .systemAudioInterrupted: true
        case .api(_, let retryable): retryable
        default: false
        }
    }

    static func fromAPI(code: String = "", type: String = "", status: Int? = nil) -> AppFailure {
        let identifier = code.lowercased()
        let category = type.lowercased()
        if identifier.contains("quota") || identifier.contains("billing") || category.contains("quota") || status == 402 {
            return .api("API 项目额度不足，请检查账单。", retryable: false)
        }
        if identifier == "invalid_api_key" || identifier.contains("authentication") || status == 401 {
            return .api("API Key 无效，请到设置更新。", retryable: false)
        }
        if identifier.contains("permission") || identifier == "model_not_found" || status == 403 || status == 404 {
            return .api("API 无法访问此接口或模型，请检查地址、模型 ID 和项目权限。", retryable: false)
        }
        if identifier.contains("rate_limit") || status == 429 {
            return .api("API 请求已限流，请稍后重试。", retryable: true)
        }
        if identifier.contains("session_expired") || category == "server_error" || (status ?? 0) >= 500 {
            return .api("API 暂时不可用，或当前连接已过期。", retryable: true)
        }
        return .api("接口拒绝了请求，请检查项目或模型配置。", retryable: false)
    }
}

