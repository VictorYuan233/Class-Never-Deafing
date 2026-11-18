import CryptoKit
import Foundation

enum APIRole: String, CaseIterable {
    case transcription, translation

    var title: String { self == .transcription ? "转写" : "翻译" }
}

struct APIEndpoint: Equatable {
    static let openAI = URL(string: "https://api.openai.com/v1")!
    let base: URL

    init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input.isEmpty ? Self.openAI.absoluteString : input),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw APISettingError.invalidAddress
        }
        parts.host = host
        parts.scheme = parts.scheme?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw APISettingError.invalidAddress }
        base = url
    }

    func url(_ path: String) -> URL { base.appending(path: path) }

    var realtimeURL: URL {
        var parts = URLComponents(url: url("realtime"), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return parts.url!
    }
}

struct APIConnection {
    let endpoint: APIEndpoint
    let key: String

    func request(_ url: URL, timeout: TimeInterval, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validateKey(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw APISettingError.invalidKey
        }
        return key
    }
}

enum APISettingError: LocalizedError {
    case invalidAddress, invalidKey, missingKey(APIRole), changedAddress(APIRole), unreadableKey

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入 API 基础地址。远程服务使用 HTTPS，本机服务可使用 HTTP。"
        case .invalidKey: "请输入有效的 API Key，密钥中不能有空格或换行。"
        case .missingKey(let role): "请先在「设置 → \(role.title)」保存 API Key。"
        case .changedAddress(let role): "「\(role.title)」的 API 地址已更改，请为这个地址输入并保存 API Key。"
        case .unreadableKey: "无法读取本地加密的 API Key，请重新输入并保存。"
        }
    }
}

struct APIKeyStore {
    struct Credential: Codable {
        let endpoint: URL
        let key: String
    }

    let folder: URL
    static let local = Self(folder: URL.applicationSupportDirectory.appending(path: "课堂字幕/API"))

    func load(_ role: APIRole) throws -> Credential? {
        let file = credentialURL(role)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            let data = try AES.GCM.open(box, using: readKey(), authenticating: Data(role.rawValue.utf8))
            return try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            throw APISettingError.unreadableKey
        }
    }

    func connection(_ role: APIRole, endpoint: APIEndpoint) throws -> APIConnection {
        guard let credential = try load(role) else { throw APISettingError.missingKey(role) }
        guard credential.endpoint == endpoint.base else { throw APISettingError.changedAddress(role) }
        return APIConnection(endpoint: endpoint, key: credential.key)
    }

    func save(_ input: String, role: APIRole, endpoint: APIEndpoint) throws {
        let credential = Credential(endpoint: endpoint.base, key: try APIConnection.validateKey(input))
        let file = folder.appending(path: "local.key")
        let destination = credentialURL(role)
        try PrivateDataLocation.check(folder)
        try PrivateDataLocation.check(file)
        try PrivateDataLocation.check(destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) {
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(credential), using: readKey(),
                                      authenticating: Data(role.rawValue.utf8))
        try sealed.combined!.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func delete(_ role: APIRole) throws {
        let file = credentialURL(role)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func credentialURL(_ role: APIRole) -> URL { folder.appending(path: "\(role.rawValue).sealed") }

    private func readKey() throws -> SymmetricKey {
        let data = try Data(contentsOf: folder.appending(path: "local.key"))
        guard data.count == 32 else { throw APISettingError.unreadableKey }
        return SymmetricKey(data: data)
    }
}

struct TranscriptionService {
    let connection: APIConnection
    let selection: TranscriptionModel
    let modelID: String
}

enum TranslationProtocol: String, CaseIterable, Identifiable {
    case responses, chat
    static let defaultChoice: Self = .responses

    var id: Self { self }
    var title: String { self == .responses ? "Responses" : "Chat Completions" }
    var path: String { self == .responses ? "responses" : "chat/completions" }

    static let help = """
        Responses（默认）使用 /responses，适用于提供此接口的服务。
        Chat Completions 使用 /chat/completions，适用于只提供聊天补全接口的兼容服务。
        两者都能流式翻译。请选择服务商支持的接口，再点「测试翻译」。
        """
}

struct TranslationService {
    let connection: APIConnection
    let format: TranslationProtocol
    let model: TranslationConfiguration
}

struct SessionAPIs {
    let transcription: TranscriptionService
    let translation: TranslationService
}
