import Foundation
import AVFoundation
import CoreMedia

@main
struct CoreChecks {
    @MainActor static func main() async throws {
        checkLanguageConfiguration()
        try checkTranslationConfiguration()
        try checkSubtitleColors()
        checkTemporaryCredential()
        checkSpeechBoundaries()
        checkTranslationSegments()
        try await checkSystemAudioConversion()
        checkCaptionScroll()
        checkRecordingClock()
        try checkExport()
        print("通过：语言、自定义模型参数、字体颜色、临时 Key、短停顿分段与双句翻译、系统音频格式转换、字幕滚动、暂停计时、自选目录自动保存。")
    }

    @MainActor private static func checkTemporaryCredential() {
        precondition(KeyStore.temporaryKey == nil)
        KeyStore.useUntilQuit("offline-test-placeholder")
        let activeKey = try? KeyStore.read()
        precondition(activeKey == "offline-test-placeholder")
        KeyStore.useUntilQuit("replacement-placeholder")
        let replacement = try? KeyStore.read()
        precondition(replacement == "replacement-placeholder")
        KeyStore.clearTemporaryKey()
        precondition(KeyStore.temporaryKey == nil)
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
        for _ in 0..<(SpeechSegmenter.sentencePauseFrames - 1) {
            precondition(!commits(segmenter.ingest(silent)))
        }
        precondition(commits(segmenter.ingest(silent)))
        precondition(segmenter.finish().isEmpty)

        var longTurn = SpeechSegmenter()
        for _ in 0..<SpeechSegmenter.longTurnFrames {
            precondition(!commits(longTurn.ingest(spoken)))
        }
        for _ in 0..<(SpeechSegmenter.longTurnPauseFrames - 1) {
            precondition(!commits(longTurn.ingest(silent)))
        }
        precondition(commits(longTurn.ingest(silent)))

        var forced = 0
        for _ in 0..<(SpeechSegmenter.maximumTurnFrames * 2 + 50) {
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

    private static func checkTranslationSegments() {
        let lesson = "  Dr. Tan measured 3.5 volts. Then the reading dropped. Is that expected? Check the leads. Record the value. "
        precondition(TranslationSegments.split(lesson) == [
            "Dr. Tan measured 3.5 volts. Then the reading dropped.",
            "Is that expected? Check the leads.",
            "Record the value.",
        ])
        precondition(TranslationSegments.split("先检查数据。然后训练模型。最后再评估。") == [
            "先检查数据。然后训练模型。", "最后再评估。",
        ])
        precondition(TranslationSegments.split("An unfinished phrase") == ["An unfinished phrase"])
        precondition(TranslationSegments.split("  ").isEmpty)
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
        for try await event in processor.events {
            switch event {
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
