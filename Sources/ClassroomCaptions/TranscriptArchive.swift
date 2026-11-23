import Foundation
import SQLite3

struct TranscriptArchive {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    static let visibleSeconds: Int64 = 20 * 60
    static let pageSize = 100
    let url: URL

    init(name: String, folder: URL = URL.applicationSupportDirectory.appending(path: "课堂字幕/字幕归档")) {
        url = folder.appending(path: name).appendingPathExtension("sqlite3")
    }

    func write(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try PrivateDataLocation.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try withDatabase(flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) { database in
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("CREATE TABLE IF NOT EXISTS captions (position INTEGER PRIMARY KEY, body TEXT NOT NULL)", in: database)
            try execute("BEGIN IMMEDIATE", in: database)
            do {
                try withStatement("INSERT OR REPLACE INTO captions VALUES (?, ?)", in: database) { statement in
                    for entry in entries {
                        try check(sqlite3_bind_int64(statement, 1, Int64(entry.id)), in: database)
                        try check(sqlite3_bind_text(statement, 2, entry.text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)),
                                  in: database)
                        try check(sqlite3_step(statement), in: database, expected: SQLITE_DONE)
                        try check(sqlite3_reset(statement), in: database)
                    }
                }
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
    }

    func read(before: Int = .max, limit: Int = .max) throws -> [Entry] {
        return try withDatabase(flags: SQLITE_OPEN_READONLY) { database in
            try withStatement("SELECT position, body FROM captions WHERE position < ? ORDER BY position DESC LIMIT ?", in: database) { statement in
                try check(sqlite3_bind_int64(statement, 1, Int64(before)), in: database)
                try check(sqlite3_bind_int64(statement, 2, Int64(limit)), in: database)
                var entries: [Entry] = []
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    let position = Int(sqlite3_column_int64(statement, 0))
                    if let text = sqlite3_column_text(statement, 1) {
                        entries.append(Entry(id: position, text: String(cString: text)))
                    }
                    result = sqlite3_step(statement)
                }
                try check(result, in: database, expected: SQLITE_DONE)
                return entries
            }
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: url)
    }

    static func render(archived: [Entry], recent: [Entry], markers: [RecordingMarker] = []) -> String {
        var entries = Dictionary(uniqueKeysWithValues: archived.map { ($0.id, $0.text) })
        for entry in recent { entries[entry.id] = entry.text }
        return TextExport.assemble(entries.keys.sorted().compactMap { entries[$0] }, markers: markers)
    }

    private func withDatabase<T>(flags: Int32, _ action: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        defer { sqlite3_close(handle) }
        try check(result, in: handle)
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        sqlite3_busy_timeout(handle, 1500)
        return try action(handle)
    }

    private func withStatement<T>(_ sql: String, in database: OpaquePointer, _ action: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        try check(result, in: database)
        guard let statement else { throw CocoaError(.fileReadUnknown) }
        return try action(statement)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil), in: database)
    }

    private func check(_ result: Int32, in database: OpaquePointer?, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else {
            throw NSError(domain: "SQLite", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
            ])
        }
    }
}
