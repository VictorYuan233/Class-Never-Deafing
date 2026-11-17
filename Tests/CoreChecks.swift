import Foundation
import AVFoundation
import CoreMedia

@main
struct CoreChecks {
    @MainActor static func main() async throws {
        checkLanguageConfiguration()
        try checkCaptionShortcuts()
        try checkTranslationConfiguration()
        try checkSubtitleColors()
        await checkTemporaryCredential()
        try await checkKeychainTimeout()
        try checkLogRetention()
        checkSpeechBoundaries()
        checkQuietMicrophone()
        checkSpeechEvidence()
        checkSegmentationLength()
        checkAudioPacketBatching()
        checkTranscriptionRecoveryRequest()
        checkRecoveryAmplification()
        checkTranscriptDrafts()
        try await checkSystemAudioConversion()
        checkCaptionScroll()
        checkRecordingClock()
        try checkExport()
        print("通过：语言、字幕窗快捷键、自定义模型参数、字体颜色、临时 Key、钥匙串后台超时、日志容量和淘汰、轻声检测、可调分句、Fast 翻译与补识别请求、系统音频格式转换与分包、实时原文交接和字幕滚动、暂停计时、自选目录自动保存。")
    }

    private static func checkTranscriptDrafts() {
        let connection = UUID()
        let retired = UUID()
        let first = UUID()
        let second = UUID()
        let indices = [first: 0, second: 1]
        var drafts = TranscriptDrafts()
        func liveText() -> String { drafts.newest(activeConnection: connection, indices: indices) }

        drafts.append("First", connection: connection, item: "item_1")
        drafts.bind(connection: connection, item: "item_1", to: first)
        precondition(liveText() == "First")
        drafts.append("Next", connection: connection, item: "item_2")
        drafts.append(" segment", connection: connection, item: "item_2")
        drafts.append(" segment", to: first)
        drafts.append("Retired text", connection: retired, item: "item_2")
        precondition(liveText() == "Next segment")
        drafts.bind(connection: connection, item: "item_2", to: second)
        drafts.append(" continues", to: second)
        precondition(liveText() == "Next segment continues")
        let oldText = drafts.remove(first)
        precondition(oldText == "First segment" && liveText() == "Next segment continues")
        drafts.remove(connection: retired)
        drafts.remove(second)
        precondition(liveText().isEmpty)
    }

    @MainActor private static func checkTemporaryCredential() async {
        precondition(KeyStore.temporaryKey == nil)
        KeyStore.useUntilQuit("offline-test-placeholder")
        let activeKey = try? await KeyStore.read()
        precondition(activeKey == "offline-test-placeholder")
        KeyStore.useUntilQuit("replacement-placeholder")
        let replacement = try? await KeyStore.read()
        precondition(replacement == "replacement-placeholder")
        KeyStore.clearTemporaryKey()
        precondition(KeyStore.temporaryKey == nil)
    }

    @MainActor private static func checkKeychainTimeout() async throws {
        let worker = KeychainWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        do {
            _ = try await worker.perform(timeout: .milliseconds(50)) {
                precondition(!Thread.isMainThread)
                release.wait()
                return "late result"
            }
            preconditionFailure("A stalled read should time out")
        } catch AppFailure.keychainTimeout {}
        do {
            _ = try await worker.perform { "overlapping read" }
            preconditionFailure("A timed-out underlying operation must not allow overlapping requests")
        } catch AppFailure.keychainBusy {}

        release.signal()
        for _ in 0..<50 {
            do {
                let value = try await worker.perform { "available again" }
                precondition(value == "available again")
                return
            } catch AppFailure.keychainBusy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        preconditionFailure("The worker did not recover after the system call returned")
    }

    private static func checkLogRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.log")
        let log = BoundedLogFile(url: url, maximumBytes: 256)
        for index in 0..<100 {
            try log.append(Data("事件-\(index)\n".utf8))
            let data = try Data(contentsOf: url)
            precondition(data.count <= log.maximumBytes)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        precondition(lines.first != "事件-0" && lines.last == "事件-99")
        precondition(lines.allSatisfy { $0.hasPrefix("事件-") })
        let positions = lines.compactMap { Int($0.dropFirst(3)) }
        precondition(positions.count == lines.count && positions == Array((positions.first ?? 100)...99))
    }

    @MainActor private static func checkLanguageConfiguration() {
        precondition(Language.source("").id == "auto")
        precondition(Language.target("").id == "zh-cn")

        func transcription(for source: Language, model: TranscriptionModel = .live) -> [String: Any] {
            let request = RealtimeConnection.configuration(source: source, model: model)
            let session = request["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            let input = audio["input"] as! [String: Any]
            return input["transcription"] as! [String: Any]
        }
        precondition(transcription(for: .automatic)["languages"] == nil)
        precondition(transcription(for: .english)["languages"] as? [String] == ["en"])
        precondition(Language.target("zh-tw").instruction.contains("Traditional"))
        let live = transcription(for: .automatic)
        precondition(live["model"] as? String == "gpt-live-transcribe")
        precondition(live["delay"] as? String == "low")
        let committed = transcription(for: .english, model: .committed)
        precondition(committed["model"] as? String == "gpt-transcribe")
        precondition(committed["delay"] == nil)
        precondition(committed["languages"] as? [String] == ["en"])
    }

    private static func checkCaptionShortcuts() throws {
        let show = CaptionKeyCombination(keyCode: 15, flags: [.command, .option], characters: "r")!
        let localized = CaptionKeyCombination(keyCode: 15, flags: [.command, .option], characters: "p")!
        let hide = CaptionKeyCombination(keyCode: 15, flags: [.command, .control], characters: "r")!
        precondition(show.display == "⌥⌘R" && show.matches(localized) && !show.matches(hide))
        precondition(CaptionKeyCombination(keyCode: 123, flags: [.control], characters: nil)?.display == "⌃←")
        precondition(CaptionKeyCombination(keyCode: 122, flags: [], characters: "\u{F704}")?.display == "F1")
        precondition(CaptionKeyCombination(keyCode: 15, flags: [.shift], characters: "R") == nil)
        let restored = try PropertyListDecoder().decode(CaptionKeyCombination.self, from: PropertyListEncoder().encode(show))
        precondition(restored == show)
    }

    private static func checkTranslationConfiguration() throws {
        let presetEffort: [TranslationModel: String] = [
            .luna: "none", .terra: "none", .sol: "low", .astra: "low", .mini54: "none",
        ]
        for preset in TranslationModel.allCases where preset != .custom {
            let config = try preset.configuration()
            precondition(config.id == preset.rawValue && config.reasoningEffort == presetEffort[preset])
            let data = try TranslationAPI.requestBody("Hello.", to: .simplified, model: config, previous: nil)
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(body["model"] as? String == preset.rawValue)
            precondition((body["reasoning"] as? [String: String])?["effort"] == presetEffort[preset])
            precondition(body["service_tier"] == nil)
            let requested = try preset.configuration(fast: true)
            let paragraph = "We tested the audio. Then we checked the result. It worked."
            let fastData = try TranslationAPI.requestBody(paragraph, to: .simplified, model: requested, previous: nil)
            let fastBody = try JSONSerialization.jsonObject(with: fastData) as! [String: Any]
            let input = try JSONSerialization.jsonObject(with: Data((fastBody["input"] as! String).utf8)) as! [String: String]
            let expectedTier = [.luna, .terra, .sol, .astra].contains(preset) ? "fast" : nil
            precondition(fastBody["service_tier"] as? String == expectedTier)
            precondition(input["translate_this_segment"] == paragraph)
        }
        let custom = try TranslationModel.custom.configuration(customID: "  ft:gpt-4.1-mini:example:lecture  ")
        let data = try TranslationAPI.requestBody("Hello.", to: .simplified, model: custom, previous: nil)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(body["model"] as? String == "ft:gpt-4.1-mini:example:lecture")
        precondition(body["reasoning"] == nil && body["stream"] as? Bool == true)
        precondition((try? TranslationModel.custom.configuration()) == nil)
        precondition((try? TranslationModel.custom.configuration(customID: "invalid model")) == nil)
    }

    private static func checkSubtitleColors() throws {
        let previousSettings = Data(#"{"size":21,"design":"serif","bold":true,"italic":false}"#.utf8)
        let olderStyle = try JSONDecoder().decode(CaptionTypography.self, from: previousSettings)
        precondition(olderStyle.size == 21 && olderStyle.design == .serif && olderStyle.bold && olderStyle.color == nil)

        var style = olderStyle
        style.color = CaptionRGB(red: 1, green: 0.8, blue: 0.1)
        let restored = try JSONDecoder().decode(CaptionTypography.self, from: JSONEncoder().encode(style))
        precondition(restored == style && CaptionTypography.translation.color == nil)
    }

    private static func checkSpeechBoundaries() {
        var segmenter = SpeechSegmenter()
        let silent = Data(count: SpeechSegmenter.bytesPerFrame)
        let spoken = Array(repeating: Int16(1800), count: SpeechSegmenter.samplesPerFrame).withUnsafeBytes { Data($0) }

        for _ in 0..<100 { precondition(segmenter.ingest(silent).isEmpty) }
        precondition(segmenter.finish().isEmpty)

        for _ in 0..<10 { precondition(segmenter.ingest(silent).isEmpty) }
        precondition(segmenter.ingest(spoken).isEmpty)
        if case .audio(let payload) = segmenter.ingest(spoken).first {
            precondition(payload.count == 11 * SpeechSegmenter.bytesPerFrame)
        } else {
            preconditionFailure("Expected pre-roll and speech")
        }

        for _ in 0..<30 { precondition(!commits(segmenter.ingest(silent))) }
        precondition(!commits(segmenter.ingest(spoken)))
        for _ in 0..<(SegmentationLength.standard.limits.pauseFrames - 1) {
            precondition(!commits(segmenter.ingest(silent)))
        }
        precondition(commits(segmenter.ingest(silent)))
        precondition(segmenter.finish().isEmpty)

        var longTurn = SpeechSegmenter()
        for _ in 0..<SegmentationLength.standard.limits.longTurnFrames {
            precondition(!commits(longTurn.ingest(spoken)))
        }
        for _ in 0..<(SegmentationLength.standard.limits.longTurnPauseFrames - 1) {
            precondition(!commits(longTurn.ingest(silent)))
        }
        precondition(commits(longTurn.ingest(silent)))

        var forced = 0
        for _ in 0..<(SegmentationLength.standard.limits.maximumFrames * 2 + 50) {
            if commits(segmenter.ingest(spoken)) { forced += 1 }
        }
        precondition(forced == 2)
        precondition(commits(segmenter.finish()))

        var shortTail = SpeechSegmenter()
        _ = shortTail.ingest(spoken)
        _ = shortTail.ingest(spoken)
        let tail = shortTail.finish()
        if case .audio(let padding) = tail.first {
            precondition(padding.count == 3 * SpeechSegmenter.bytesPerFrame)
        } else {
            preconditionFailure("Expected padding to the minimum commit duration")
        }
        precondition(commits(tail))
    }

    private static func checkQuietMicrophone() {
        let quiet = Array(repeating: Int16(25), count: SpeechSegmenter.samplesPerFrame).withUnsafeBytes { Data($0) }
        let speech = Array(repeating: Int16(115), count: SpeechSegmenter.samplesPerFrame).withUnsafeBytes { Data($0) }
        var microphone = SpeechSegmenter(sensitivity: .microphone)
        var system = SpeechSegmenter(sensitivity: .system)
        for _ in 0..<100 {
            precondition(microphone.ingest(quiet).isEmpty)
            precondition(system.ingest(quiet).isEmpty)
        }
        precondition(microphone.ingest(speech).isEmpty)
        precondition(!microphone.ingest(speech).isEmpty)
        precondition(system.ingest(speech).isEmpty && system.ingest(speech).isEmpty)
        for _ in 0..<(SegmentationLength.standard.limits.pauseFrames - 1) {
            precondition(!commits(microphone.ingest(quiet)))
        }
        precondition(commits(microphone.ingest(quiet)))
    }

    private static func checkSegmentationLength() {
        let voiced = Array(repeating: Int16(1800), count: SpeechSegmenter.samplesPerFrame).withUnsafeBytes { Data($0) }
        let silent = Data(count: SpeechSegmenter.bytesPerFrame)
        var short = SpeechSegmenter(length: .short)
        var standard = SpeechSegmenter(length: .standard)
        for _ in 0..<100 {
            _ = short.ingest(voiced)
            _ = standard.ingest(voiced)
        }
        for _ in 0..<29 {
            precondition(!commits(short.ingest(silent)))
            precondition(!commits(standard.ingest(silent)))
        }
        precondition(commits(short.ingest(silent)))
        precondition(!commits(standard.ingest(silent)))

        var legacy = SpeechSegmenter(length: .extended)
        for _ in 0..<500 { precondition(!commits(legacy.ingest(voiced))) }
        for _ in 0..<74 { precondition(!commits(legacy.ingest(silent))) }
        precondition(commits(legacy.ingest(silent)))
        for _ in 0..<1499 { precondition(!commits(legacy.ingest(voiced))) }
        precondition(commits(legacy.ingest(voiced)))

    }

    private static func checkAudioPacketBatching() {
        let frameSize = SpeechSegmenter.bytesPerFrame
        let b = Data(repeating: 2, count: frameSize)
        let first = Data(repeating: 1, count: frameSize * 9)
        let next = Data(repeating: 3, count: frameSize)
        let start = ContinuousClock.now
        var batcher = AudioPacketBatcher()
        var yielded = batcher.append(.audio(first), now: start)
        for offset in 1...9 {
            yielded += batcher.append(.audio(b), now: start.advanced(by: .milliseconds(offset * 20)))
        }
        let boundary = start.advanced(by: .milliseconds(200))
        yielded += batcher.append(.commit(SpeechBoundary(voicedFrames: 10, silentFrames: 3)), now: boundary)
        yielded += batcher.append(.audio(next), now: boundary.advanced(by: .milliseconds(20)))
        precondition(yielded.count == 6)
        var beforeCommit = Data()
        for packet in yielded.prefix(4) {
            guard case .audio(let chunk) = packet.event else { preconditionFailure("Audio order changed") }
            beforeCommit.append(chunk)
        }
        precondition(beforeCommit == first + Data(repeating: 2, count: frameSize * 9))
        precondition(yielded[1].queuedAt == start.advanced(by: .milliseconds(20)))
        guard case .commit(let signal) = yielded[4].event else { preconditionFailure("Expected segment boundary") }
        precondition(signal.voicedFrames == 10 && signal.silentFrames == 3 && yielded[4].queuedAt == boundary)
        guard case .audio(let afterCommit) = yielded[5].event else { preconditionFailure("Next turn must start immediately") }
        precondition(afterCommit == next)
    }

    private static func checkTranscriptionRecoveryRequest() {
        let pcm = Data([0x12, 0x34, 0x56, 0x78])
        let request = TranscriptionRecoveryAPI.request(pcm, source: .english, key: "offline")
        precondition(request.httpMethod == "POST" && request.url?.path == "/v1/audio/transcriptions")
        let body = request.httpBody!
        let fields = String(decoding: body, as: UTF8.self)
        precondition(fields.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        precondition(fields.contains("name=\"language\"\r\n\r\nen"))
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        precondition(body.subdata(in: (riff + 24)..<(riff + 28)) == Data([0xc0, 0x5d, 0, 0]))
        precondition(body.subdata(in: (riff + 40)..<(riff + 48)) == Data([4, 0, 0, 0]) + pcm)
        let autoBody = TranscriptionRecoveryAPI.request(pcm, source: .automatic, key: "offline").httpBody!
        precondition(!String(decoding: autoBody, as: UTF8.self).contains("name=\"language\""))
    }

    private static func checkSpeechEvidence() {
        let speech = Array(repeating: Int16(250), count: SpeechSegmenter.samplesPerFrame).withUnsafeBytes { Data($0) }
        let silence = Data(count: SpeechSegmenter.bytesPerFrame)
        var segmenter = SpeechSegmenter(sensitivity: .microphone, length: .short)
        for voicedFrames in [2, 8] {
            for _ in 0..<voicedFrames { _ = segmenter.ingest(speech) }
            for _ in 0..<29 { _ = segmenter.ingest(silence) }
            guard case .commit(let signal) = segmenter.ingest(silence).last else {
                preconditionFailure("Expected a boundary after the silence")
            }
            precondition(signal.voicedFrames == voicedFrames && signal.silentFrames == 30)
            precondition(signal.hasSustainedSignal == (voicedFrames >= 8))
        }
    }

    private static func checkRecoveryAmplification() {
        func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBytes { Data($0) } }
        precondition(RecoveryAudio.amplifyQuietPCM(pcm([200, -500, 0])) == pcm([800, -2000, 0]))
        precondition(RecoveryAudio.amplifyQuietPCM(pcm([-8000, 4000])) == pcm([-16000, 8000]))
        precondition(RecoveryAudio.amplifyQuietPCM(pcm([0, 0])) == pcm([0, 0]))
        precondition(RecoveryAudio.amplifyQuietPCM(pcm([Int16.min, 500])) == pcm([Int16.min, 500]))
    }

    private static func commits(_ events: [AudioEvent]) -> Bool {
        events.contains { if case .commit = $0 { return true }; return false }
    }

    private static func checkSystemAudioConversion() async throws {
        let frameCount = 4_800
        let samples = [Float](repeating: 0.15, count: frameCount)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        var data: CMBlockBuffer?
        let length = frameCount * MemoryLayout<Float>.size
        let bufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &data
        )
        precondition(bufferStatus == noErr)
        let dataStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data!, offsetIntoDestination: 0, dataLength: length)
        }
        precondition(dataStatus == noErr)
        var sample: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data!, formatDescription: format.formatDescription,
            sampleCount: frameCount, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
        )
        precondition(sampleStatus == noErr)

        let processor = AudioProcessor()
        processor.queue.sync { processor.ingestSystemSample(sample!) }
        processor.finish()
        var audioBytes = 0
        var committed = false
        for try await packet in processor.events {
            switch packet.event {
            case .audio(let data): audioBytes += data.count
            case .commit: committed = true
            }
        }
        precondition(audioBytes >= 5 * SpeechSegmenter.bytesPerFrame && committed)
    }

    private static func checkCaptionScroll() {
        var follow = CaptionScrollFollow()
        let viewport: CGFloat = 200
        let row: CGFloat = 20
        precondition(!follow.shouldScroll(.init(height: 340, bottom: 200), viewport: viewport, lineHeight: row))
        precondition(follow.shouldScroll(.init(height: 360, bottom: 220), viewport: viewport, lineHeight: row))
        precondition(!follow.shouldScroll(.init(height: 360, bottom: 300), viewport: viewport, lineHeight: row))
        precondition(!follow.isFollowing)
        precondition(!follow.shouldScroll(.init(height: 410, bottom: 350), viewport: viewport, lineHeight: row))
        precondition(!follow.shouldScroll(.init(height: 410, bottom: 235), viewport: viewport, lineHeight: row))
        precondition(follow.isFollowing)
        precondition(follow.shouldScroll(.init(height: 430, bottom: 255), viewport: viewport, lineHeight: row))
    }

    private static func checkRecordingClock() {
        var clock = RecordingClock()
        let initial = SuspendingClock().now
        clock.resume(at: initial)
        clock.pause(at: initial.advanced(by: .seconds(15)))
        precondition(clock.elapsed(at: initial.advanced(by: .seconds(40))) == .seconds(15))
        clock.resume(at: initial.advanced(by: .seconds(40)))
        clock.pause(at: initial.advanced(by: .seconds(46)))
        precondition(clock.elapsed(at: initial.advanced(by: .seconds(60))) == .seconds(21))
        precondition(clock.display == "00:00:21")
    }

    private static func checkExport() throws {
        let results = [
            Caption(original: "First\nline", translation: "第一段", originalFinal: true, translationFinal: true),
            Caption(original: "Second", translation: "断开的草稿", originalFinal: true),
            Caption(original: "Unfinished raw transcript", translation: ""),
        ]
        let exported = TextExport.render(results)
        precondition(exported == "First line\n第一段\n\nSecond\n[翻译未完成]\n")
        precondition(String(data: Data(exported.utf8), encoding: .utf8) == exported)
        precondition(TextExport.render([]).isEmpty)

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sameTime = Date(timeIntervalSince1970: 0)
        let first = try TextExport.saveAutomatically(exported, in: folder, now: sameTime)
        let second = try TextExport.saveAutomatically("另一节课\n", in: folder, createFolder: false, now: sameTime)
        let firstText = try String(contentsOf: first, encoding: .utf8)
        let secondText = try String(contentsOf: second, encoding: .utf8)
        precondition(first != second && first.pathExtension == "txt")
        precondition(firstText == exported && secondText == "另一节课\n")
        let unavailable = folder.appending(path: "disconnected-folder", directoryHint: .isDirectory)
        let write = try? TextExport.saveAutomatically(exported, in: unavailable, createFolder: false)
        precondition(write == nil && !FileManager.default.fileExists(atPath: unavailable.path))
    }
}
