import Darwin
import Foundation
import os

struct BoundedLogFile {
    let url: URL
    let maximumBytes: Int

    func append(_ line: Data, shouldWrite: () -> Bool = { true }) throws {
        guard maximumBytes > 0, !line.isEmpty, line.count <= maximumBytes else { return }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = folder.appendingPathComponent(".\(url.lastPathComponent).lock")
        let lock = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        guard shouldWrite() else { return }
        // The folder lock remains valid even when the log is replaced atomically.
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try FileHandle(forUpdating: url)
            defer { try? file.close() }
            let size = try file.seekToEnd()
            if size <= UInt64(maximumBytes - line.count) {
                guard shouldWrite() else { return }
                try file.write(contentsOf: line)
                return
            }
            let keep = min(maximumBytes - line.count, maximumBytes - maximumBytes / 4)
            let start = size - min(size, UInt64(keep))
            try file.seek(toOffset: start)
            let tail = try file.read(upToCount: keep) ?? Data()
            var updated = Data()
            if start == 0 {
                updated.append(tail)
            } else if let boundary = tail.firstIndex(of: 10) {
                updated.append(tail[tail.index(after: boundary)...])
            }
            updated.append(line)
            guard shouldWrite() else { return }
            try replace(with: updated)
        } else {
            try replace(with: line)
        }
    }

    private func replace(with data: Data) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum AppLog {
    private struct RecordingState {
        var enabled: Bool
        var generation: UInt64 = 0
    }

    static let maximumBytes = 1024 * 1024
    private static let recordingKey = "diagnosticsLoggingEnabled"
    private static let recording = OSAllocatedUnfairLock(initialState: RecordingState(
        enabled: UserDefaults.standard.object(forKey: recordingKey) as? Bool ?? true
    ))
    private static let queue = DispatchQueue(label: "classroom-captions.diagnostics", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private static let file = BoundedLogFile(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Class Never Deafing/diagnostics.log"),
        maximumBytes: maximumBytes
    )

    static var isEnabled: Bool { recording.withLock { $0.enabled } }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        recording.withLock {
            guard $0.enabled != enabled else { return }
            $0.enabled = enabled
            $0.generation &+= 1
        }
        UserDefaults.standard.set(enabled, forKey: recordingKey)
    }

    static func launch(version: String, build: String) {
        write("app.launch", detail: "version=\(version) build=\(build)")
    }

    static func event(_ name: StaticString, number: Int? = nil) {
        write(name, detail: number.map { "value=\($0)" })
    }

    static func latency(_ name: StaticString, since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        event(name, number: milliseconds)
    }

    static func audioSignal(peak: Double, threshold: Double, voicedFrames: Int) {
        func decibels(_ rms: Double) -> Int {
            Int((20 * log10(max(1, rms) / 32_768)).rounded())
        }
        write("audio.signal_10s", detail: "peak_dbfs=\(decibels(peak)) gate_dbfs=\(decibels(threshold)) voiced_frames=\(voicedFrames)")
    }

    static func failure(_ name: StaticString, _ error: Error) {
        if let failure = error as? AppFailure {
            write(name, detail: failure.diagnosticCode)
        } else if error is CancellationError {
            write(name, detail: "cancelled")
        } else {
            let cause = error as NSError
            let category = cause.domain == NSURLErrorDomain ? "network" : "system"
            write(name, detail: "\(category) code=\(cause.code)")
        }
    }

    static func currentFile() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if FileManager.default.fileExists(atPath: file.url.path) {
                    continuation.resume(returning: file.url)
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    // Entries contain app-defined events and numeric codes, never request bodies or private strings.
    private static func write(_ event: StaticString, detail: String?) {
        let generation = recording.withLock { $0.enabled ? $0.generation : nil }
        guard let generation else { return }
        let timestamp = Date()
        queue.async {
            // Drop queued lines from earlier recording periods, including after reenabling.
            let shouldWrite = {
                recording.withLock { $0.enabled && $0.generation == generation }
            }
            guard shouldWrite() else { return }
            let suffix = detail.map { " \($0)" } ?? ""
            let data = Data("\(formatter.string(from: timestamp)) \(event)\(suffix)\n".utf8)
            do {
                try file.append(data, shouldWrite: shouldWrite)
            } catch {
                let code = (error as NSError).code
                NSLog("Class Never Deafing diagnostics write failed (%ld)", code)
            }
        }
    }
}
