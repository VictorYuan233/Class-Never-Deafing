import Foundation
import Security

@MainActor
enum KeyStore {
    private static let worker = KeychainWorker()
    private static var temporaryRevision = 0
    private(set) static var temporaryKey: String?

    static func read() async throws -> String? {
        if let temporaryKey { return temporaryKey }
        AppLog.event("keychain.read.begin")
        do {
            let stored = try await worker.perform(timeout: .seconds(10)) { try KeychainQueries.read() }
            AppLog.event(stored == nil ? "keychain.read.missing" : "keychain.read.success")
            return temporaryKey ?? stored
        } catch {
            AppLog.failure("keychain.read.failed", error)
            if let temporaryKey, !Task.isCancelled { return temporaryKey }
            throw error
        }
    }

    static func hasSavedKey() async throws -> Bool {
        try await worker.perform(timeout: .seconds(5)) { try KeychainQueries.hasSavedKey() }
    }

    static func save(_ key: String) async throws {
        let revision = temporaryRevision
        AppLog.event("keychain.save.begin")
        do {
            try await worker.perform { try KeychainQueries.save(key) }
            if temporaryRevision == revision { clearTemporaryKey() }
            AppLog.event("keychain.save.success")
        } catch {
            AppLog.failure("keychain.save.failed", error)
            throw error
        }
    }

    static func useUntilQuit(_ key: String) {
        temporaryRevision += 1
        temporaryKey = key
    }

    static func clearTemporaryKey() {
        temporaryRevision += 1
        temporaryKey = nil
    }

    static func delete() async throws {
        AppLog.event("keychain.delete.begin")
        do {
            try await worker.perform { try KeychainQueries.delete() }
            AppLog.event("keychain.delete.success")
        } catch {
            AppLog.failure("keychain.delete.failed", error)
            throw error
        }
    }
}

private enum KeychainQueries {
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.classneverdeafing.captions.openai",
        kSecAttrAccount as String: "user-api-key",
    ]
    static func read() throws -> String? {
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
    }

    static func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AppFailure.keychain(status) }
    }
}

@MainActor
final class KeychainWorker {
    @MainActor
    private final class Reply<Value> {
        var continuation: CheckedContinuation<Value, Error>?

        func complete(_ result: Result<Value, Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    private let queue = DispatchQueue(label: "classroom-captions.keychain", qos: .userInitiated)
    private var isBusy = false

    func perform<Value: Sendable>(
        timeout: Duration? = nil,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !isBusy else { throw AppFailure.keychainBusy }
        isBusy = true
        let reply = Reply<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.continuation = continuation
                let timer = timeout.map { duration in
                    Task { @MainActor in
                        do {
                            try await Task.sleep(for: duration)
                            reply.complete(.failure(AppFailure.keychainTimeout))
                        } catch { return }
                    }
                }
                queue.async {
                    let result = Result(catching: operation)
                    Task { @MainActor in
                        self.isBusy = false
                        timer?.cancel()
                        reply.complete(result)
                    }
                }
            }
        } onCancel: {
            // Reads can return early. A save or delete must report its actual result.
            if timeout != nil {
                Task { @MainActor in reply.complete(.failure(CancellationError())) }
            }
        }
    }
}
