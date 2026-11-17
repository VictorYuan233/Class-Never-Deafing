import Foundation
import NaturalLanguage
import Security

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
    var original = ""
    var translation = ""
    var originalFinal = false
    var translationFinal = false
    var originalFailed = false
    var translationFailed = false
    var translationLanguage = Language.simplified
}

enum TranslationSegments {
    static func split(_ transcript: String) -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var groups: [String] = []
        var groupStart = text.startIndex
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            count += 1
            if count == 2 {
                groups.append(String(text[groupStart..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                groupStart = range.upperBound
                count = 0
            }
            return true
        }
        let tail = text[groupStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { groups.append(tail) }
        return groups
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case live = "gpt-live-transcribe"
    case committed = "gpt-transcribe"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "GPT-Live-Transcribe · 实时"
        case .committed: "GPT-Transcribe · 分段后转写"
        }
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

    var id: String { rawValue }
    var label: String {
        switch self {
        case .luna: "GPT-6 Luna · 低成本"
        case .terra: "GPT-6.1 Terra"
        case .sol: "GPT-6.1 Sol"
        case .astra: "GPT-6 Astra"
        case .mini54: "GPT-5.4 mini"
        case .mini41: "GPT-4.1 mini"
        case .custom: "自定义"
        }
    }

    func configuration(customID: String = "") throws -> TranslationConfiguration {
        switch self {
        case .custom:
            let id = customID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw AppFailure.translationModelName
            }
            return TranslationConfiguration(id: id, reasoningEffort: nil)
        case .luna, .terra, .mini54:
            return TranslationConfiguration(id: rawValue, reasoningEffort: "none")
        case .sol, .astra:
            return TranslationConfiguration(id: rawValue, reasoningEffort: "low")
        case .mini41:
            return TranslationConfiguration(id: rawValue, reasoningEffort: nil)
        }
    }
}

struct TranslationConfiguration: Equatable {
    static let defaultModel = TranslationConfiguration(id: TranslationModel.luna.rawValue, reasoningEffort: "none")

    let id: String
    let reasoningEffort: String?
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
        let seconds = elapsed().components.seconds
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
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
            return original + "\n" + target
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    static func saveAutomatically(_ content: String, in folder: URL, createFolder: Bool = true, now: Date = Date()) throws -> URL {
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        let url = folder.appendingPathComponent("课堂字幕-\(date.string(from: now))-\(suffix).txt")
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
    case translationModelName
    case api(String, retryable: Bool)
    case keychain(OSStatus)

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
        case .translationModelName: "请在「设置 → 模型」填写完整的 OpenAI 模型 ID，ID 中不可包含空格或换行。"
        case .api(let message, _): message
        case .keychain(errSecAuthFailed):
            "钥匙串认证失败（−25293）。请解锁「登录」钥匙串并允许访问，再试一次。"
        case .keychain(errSecInteractionNotAllowed):
            "钥匙串无法请求授权（−25308）。请先解锁「登录」钥匙串，再试一次。"
        case .keychain(errSecUserCanceled):
            "钥匙串授权已取消（−128）。可以重试，或选择仅本次使用。"
        case .keychain(let status):
            "无法访问 macOS 钥匙串（\(status)）。"
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
            return .api("OpenAI 项目额度不足，请检查 API 账单。", retryable: false)
        }
        if identifier == "invalid_api_key" || identifier.contains("authentication") || status == 401 {
            return .api("OpenAI API Key 无效，请到设置更新。", retryable: false)
        }
        if identifier.contains("permission") || identifier == "model_not_found" || status == 403 || status == 404 {
            return .api("OpenAI 项目无法访问所需模型，请检查项目权限。", retryable: false)
        }
        if identifier.contains("rate_limit") || status == 429 {
            return .api("OpenAI 请求已限流，请稍后重试。", retryable: true)
        }
        if identifier.contains("session_expired") || category == "server_error" || (status ?? 0) >= 500 {
            return .api("OpenAI 服务暂时不可用，或当前连接已过期。", retryable: true)
        }
        return .api("OpenAI 拒绝了请求，请检查项目或模型配置。", retryable: false)
    }
}

@MainActor
enum KeyStore {
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.classneverdeafing.captions.openai",
        kSecAttrAccount as String: "user-api-key",
    ]
    private(set) static var temporaryKey: String?

    static func read() throws -> String? {
        if let temporaryKey { return temporaryKey }
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func hasSavedKey() throws -> Bool {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    static func save(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)]
        let record = identity.merging(value) { _, new in new }
        let status = SecItemAdd(record as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(identity as CFDictionary, value as CFDictionary))
        } else {
            try check(status)
        }
        clearTemporaryKey()
    }

    static func useUntilQuit(_ key: String) {
        temporaryKey = key
    }

    static func clearTemporaryKey() {
        temporaryKey = nil
    }

    static func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AppFailure.keychain(status) }
    }
}
