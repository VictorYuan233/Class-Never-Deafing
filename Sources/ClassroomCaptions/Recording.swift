import AVFoundation
import Foundation
import os

final class SessionRecording: @unchecked Sendable {
    struct Outcome {
        var url: URL?
        var warning: String?
    }

    let name = SessionExport.name()
    private struct CaptureProgress {
        var samples: Int64 = 0
        var overrun = false
    }

    private let queue = DispatchQueue(label: "classroom-captions.recording", qos: .utility)
    private let slots = DispatchSemaphore(value: 64)
    private let progress = OSAllocatedUnfairLock(initialState: CaptureProgress())
    private let stagingFolder: URL
    private let encoder: URL?
    private var file: AVAudioFile?
    private var hasAudio = false
    private var writeFailed = false
    private var outcome: Outcome?

    init(stagingFolder: URL = URL.applicationSupportDirectory.appending(path: "课堂字幕/未归档录音", directoryHint: .isDirectory),
         encoder: URL? = Bundle.main.url(forAuxiliaryExecutable: "lame")) {
        self.stagingFolder = stagingFolder
        self.encoder = encoder
    }

    // The capture processor owns each buffer and never mutates it after submission.
    func append(_ buffer: AVAudioPCMBuffer) -> Int64 {
        let (offset, overrun) = progress.withLock { progress in
            let offset = progress.samples
            progress.samples += Int64(buffer.frameLength)
            return (offset, progress.overrun)
        }
        guard !overrun else { return offset }
        guard slots.wait(timeout: .now()) == .success else {
            progress.withLock { $0.overrun = true }
            return offset
        }
        queue.async {
            defer { self.slots.signal() }
            guard self.outcome == nil, !self.writeFailed else { return }
            do {
                if self.file == nil {
                    try PrivateDataLocation.check(self.stagingFolder)
                    try PrivateDataLocation.check(self.stagingURL)
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
        return offset
    }

    func finish(to destination: SessionExport?) async -> Outcome {
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

    func discard() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeStaging()
                for url in [self.stagingURL, self.encodedURL] {
                    do { try FileManager.default.removeItem(at: url) }
                    catch CocoaError.fileNoSuchFile {}
                    catch CocoaError.fileReadNoSuchFile {}
                    catch { AppLog.failure("recording.discard.failed", error) }
                }
                self.outcome = Outcome()
                continuation.resume()
            }
        }
    }

    private var stagingURL: URL {
        stagingFolder.appendingPathComponent(name).appendingPathExtension("wav")
    }

    private var encodedURL: URL { stagingURL.deletingPathExtension().appendingPathExtension("mp3") }

    private func closeStaging() {
        if #available(macOS 15, *) { file?.close() }
        file = nil
    }

    private func finalize(to destination: SessionExport?) -> Outcome {
        closeStaging()
        let wasOverrun = progress.withLock { $0.overrun }
        if wasOverrun { AppLog.event("recording.overrun") }
        let incomplete = writeFailed || wasOverrun
        guard hasAudio else {
            try? FileManager.default.removeItem(at: stagingURL)
            return Outcome(warning: incomplete ? "录音写入失败。请检查可用磁盘空间。" : nil)
        }
        let mp3 = encodedURL
        var recording = stagingURL
        var warnings: [String] = []
        if incomplete { warnings.append("录音写入中断，已保留录到的部分。") }
        do {
            try encodeMP3(to: mp3)
            recording = mp3
            try? FileManager.default.removeItem(at: stagingURL)
        } catch {
            AppLog.failure("recording.encode.failed", error)
            try? FileManager.default.removeItem(at: mp3)
            warnings.append("MP3 编码失败，已保留 WAV 录音。")
        }
        guard let destination else {
            return Outcome(url: recording, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        }
        do {
            let url = try destination.url(endingIn: recording.pathExtension)
            try FileManager.default.moveItem(at: recording, to: url)
            AppLog.event("recording.saved")
            return Outcome(url: url, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        } catch {
            AppLog.failure("recording.move.failed", error)
            warnings.append("未能写入所选目录，录音已保留在「未归档录音」。")
            return Outcome(url: recording, warning: warnings.joined(separator: " "))
        }
    }

    private func encodeMP3(to url: URL) throws {
        guard let encoder else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = encoder
        process.arguments = ["--quiet", "-m", "m", "-b", "64", "--resample", "24", stagingURL.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MP3Encoder", code: Int(process.terminationStatus))
        }
    }
}
