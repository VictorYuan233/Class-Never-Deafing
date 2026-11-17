import AVFoundation
import Foundation
import os

final class SessionRecording: @unchecked Sendable {
    struct Outcome {
        var url: URL?
        var warning: String?
    }

    let name = SessionExport.name()
    private let queue = DispatchQueue(label: "classroom-captions.recording", qos: .utility)
    private let slots = DispatchSemaphore(value: 64)
    private let overrun = OSAllocatedUnfairLock(initialState: false)
    private let stagingFolder: URL
    private var file: AVAudioFile?
    private var hasAudio = false
    private var writeFailed = false
    private var outcome: Outcome?

    init(stagingFolder: URL = URL.applicationSupportDirectory.appending(path: "课堂字幕/未归档录音", directoryHint: .isDirectory)) {
        self.stagingFolder = stagingFolder
    }

    // The capture processor owns each buffer and never mutates it after submission.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard !overrun.withLock({ $0 }) else { return }
        guard slots.wait(timeout: .now()) == .success else {
            overrun.withLock { $0 = true }
            return
        }
        queue.async {
            defer { self.slots.signal() }
            guard self.outcome == nil, !self.writeFailed else { return }
            do {
                if self.file == nil {
                    try FileManager.default.createDirectory(at: self.stagingFolder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    self.file = try AVAudioFile(forWriting: self.stagingURL, settings: buffer.format.settings,
                                                commonFormat: buffer.format.commonFormat,
                                                interleaved: buffer.format.isInterleaved)
                }
                try self.file?.write(from: buffer)
                self.hasAudio = true
            } catch {
                self.writeFailed = true
                AppLog.failure("recording.write.failed", error)
            }
        }
    }

    func finish(to destination: SessionExport) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                if let outcome = self.outcome {
                    continuation.resume(returning: outcome)
                    return
                }
                let outcome = self.finalize(to: destination)
                self.outcome = outcome
                continuation.resume(returning: outcome)
            }
        }
    }

    private var stagingURL: URL {
        stagingFolder.appendingPathComponent(name).appendingPathExtension("wav")
    }

    private func finalize(to destination: SessionExport) -> Outcome {
        if #available(macOS 15, *) { file?.close() }
        file = nil
        let wasOverrun = overrun.withLock { $0 }
        if wasOverrun { AppLog.event("recording.overrun") }
        let incomplete = writeFailed || wasOverrun
        guard hasAudio else {
            try? FileManager.default.removeItem(at: stagingURL)
            return Outcome(warning: incomplete ? "录音写入失败。请检查可用磁盘空间。" : nil)
        }
        do {
            let url = try destination.url(endingIn: "wav")
            try FileManager.default.moveItem(at: stagingURL, to: url)
            AppLog.event("recording.saved")
            return Outcome(url: url, warning: incomplete ? "录音写入中断，已保留录到的部分。" : nil)
        } catch {
            AppLog.failure("recording.move.failed", error)
            let warning = incomplete
                ? "未能写入所选目录，已在「未归档录音」中保留部分录音。"
                : "未能写入所选目录，录音已保留在「未归档录音」。"
            return Outcome(url: stagingURL, warning: warning)
        }
    }
}
