import Foundation
import AVFoundation

@main
struct CoreChecks {
    @MainActor static func main() async throws {
        checkLanguageConfiguration()
        try checkCaptionShortcuts()
        try checkTranslationConfiguration()
        try checkSubtitleColors()
        try checkAPISettings()
        try checkLogRetention()
        checkSpeechBoundaries()
        checkQuietMicrophone()
        checkSpeechEvidence()
        checkSegmentationLength()
        checkAudioPacketBatching()
        checkTranscriptionRecoveryRequest()
        checkRecoveryAmplification()
        checkTranscriptDrafts()
        checkFailureRows()
        checkSoundActivity()
        try await checkSystemAudioConversion()
        checkCaptionScroll()
        checkRecordingClock()
        try checkExport()
        try checkPrivateDataLocation()
        try checkExportArchive()
        try await checkSessionRecording()
        print("通过：独立 API 地址与密钥、密钥加密和错误脱敏、翻译与转写请求、字幕窗快捷键、诊断日志、音频分段、字幕录音配对保存。")
    }

    private static func checkTranscriptDrafts() {
        let connection = UUID()
        let retired = UUID()
        let first = UUID()
        let second = UUID()
        var drafts = TranscriptDrafts()

        drafts.append("First", connection: connection, item: "item_1")
        drafts.bind(connection: connection, item: "item_1", to: first)
        precondition(drafts.snapshot().bound[first] == "First")
        drafts.append("Next", connection: connection, item: "item_2")
        drafts.append(" segment", connection: connection, item: "item_2")
        drafts.append(" segment", to: first)
        drafts.append("Retired text", connection: retired, item: "item_2")
        drafts.append("  ", connection: connection, item: "blank")
        precondition(drafts.snapshot().unbound.map(\.text) == ["Next segment", "Retired text"])
        precondition(drafts.snapshot().bound[first] == "First segment")
        drafts.bind(connection: connection, item: "item_2", to: second)
        drafts.append(" continues", to: second)
        precondition(drafts.snapshot().bound[second] == "Next segment continues")
        let oldText = drafts.remove(first)
        precondition(oldText == "First segment" && drafts.snapshot().bound[second] == "Next segment continues")
        drafts.remove(connection: retired)
        drafts.remove(second)
        precondition(drafts.snapshot() == TranscriptDrafts.Snapshot())
    }

    private static func checkFailureRows() {
        let firstFailure = Caption(originalFailed: true)
        let missedAgain = Caption(originalFailed: true)
        let newSpeech = Caption()
        let nextFailure = Caption(originalFailed: true)
        let captions = [firstFailure, Caption(), missedAgain, newSpeech, nextFailure, Caption(originalFailed: true)]
        let rows = Caption.visibleRows(captions, drafts: [newSpeech.id: "Still speaking."])
        precondition(rows.map(\.id) == [firstFailure.id, newSpeech.id, nextFailure.id])
        precondition(rows[1].original == "Still speaking." && !rows[1].originalFinal)
        precondition(Caption.visibleRows(captions, drafts: [:]).map(\.id) == [firstFailure.id])
    }

    private static func checkSoundActivity() {
        let start = SuspendingClock().now
        var activity = SoundActivity()
        activity.ingest(audible: true, at: start)
        activity.ingest(audible: false, at: start.advanced(by: .milliseconds(20)))
        precondition(activity.lastHeardAt == nil)
        for frame in 2...5 {
            activity.ingest(audible: true, at: start.advanced(by: .milliseconds(frame * 20)))
        }
        precondition(activity.lastHeardAt == start.advanced(by: .milliseconds(100)))
        activity.ingest(audible: true, at: start.advanced(by: .milliseconds(120)))
        activity.ingest(audible: false, at: start.advanced(by: .seconds(5)))
        precondition(activity.lastHeardAt == start.advanced(by: .milliseconds(120)))
    }

    private static func checkAPISettings() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = APIKeyStore(folder: folder)
        let transcription = try APIEndpoint("https://speech.example/v1/")
        let translation = try APIEndpoint("https://text.example/v2")
        let speechKey = "test-speech-credential"
        let textKey = "test-text-credential"
        try store.save(speechKey, role: .transcription, endpoint: transcription)
        try store.save(textKey, role: .translation, endpoint: translation)
        let speech = try store.connection(.transcription, endpoint: transcription)
        let text = try store.connection(.translation, endpoint: translation)
        precondition(speech.key == speechKey && text.key == textKey)
        precondition(transcription.realtimeURL.absoluteString == "wss://speech.example/v1/realtime?intent=transcription")
        precondition((try? store.connection(.transcription, endpoint: translation)) == nil)
        precondition((try? APIEndpoint("http://speech.example/v1")) == nil)
        precondition((try? APIEndpoint("https://user@speech.example/v1")) == nil)
        precondition((try? APIConnection.validateKey("line\nbreak")) == nil)
        let encrypted = try Data(contentsOf: folder.appending(path: "transcription.sealed"))
        precondition(encrypted.range(of: Data(speechKey.utf8)) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "local.key").path)[.posixPermissions] as? Int
        precondition(mode == 0o600)
        try store.delete(.transcription)
        let deleted = try store.load(.transcription)
        let retained = try store.load(.translation)
        precondition(deleted == nil && retained?.key == textKey)
        let failureBody = Data(#"{"error":{"code":"invalid_api_key","message":"Rejected test-text-credential"}}"#.utf8)
        let failure = APIResponseError.describe(failureBody, status: 401, key: textKey).localizedDescription
        precondition(failure.contains("HTTP 401") && failure.contains("invalid_api_key") && failure.contains("Rejected"))
        precondition(!failure.contains(textKey))
        let body = try TranslationAPI.requestBody("Hello", to: .simplified, model: TranslationModel.custom.configuration(customID: "third-party", fast: true), previous: nil, format: .chat)
        let chat = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(chat["model"] as? String == "third-party" && chat["service_tier"] as? String == "fast")
        precondition((chat["messages"] as? [[String: String]])?.last?["content"]?.contains("Hello") == true)
        let selected = try TranscriptionModel.custom.modelID(customID: " whisper-1 ")
        precondition(selected == "whisper-1")
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
        let api = APIConnection(endpoint: try! APIEndpoint("https://speech.example/v1"), key: "offline")
        let request = TranscriptionRecoveryAPI.request(pcm, source: .english, api: api)
        precondition(request.httpMethod == "POST" && request.url?.path == "/v1/audio/transcriptions")
        precondition(request.url?.host == "speech.example" && request.value(forHTTPHeaderField: "Authorization") == "Bearer offline")
        let body = request.httpBody!
        let fields = String(decoding: body, as: UTF8.self)
        precondition(fields.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        precondition(fields.contains("name=\"language\"\r\n\r\nen"))
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        precondition(body.subdata(in: (riff + 24)..<(riff + 28)) == Data([0xc0, 0x5d, 0, 0]))
        precondition(body.subdata(in: (riff + 40)..<(riff + 48)) == Data([4, 0, 0, 0]) + pcm)
        let autoBody = TranscriptionRecoveryAPI.request(pcm, source: .automatic, api: api, model: "whisper-1").httpBody!
        precondition(!String(decoding: autoBody, as: UTF8.self).contains("name=\"language\""))
        precondition(String(decoding: autoBody, as: UTF8.self).contains("whisper-1"))
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
        let frameCount: AVAudioFrameCount = 4_800
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: interleaved)!
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            input.frameLength = frameCount
            input.floatChannelData![0].update(repeating: 0.15, count: Int(frameCount))
            try await checkSystemAudioPackets(input)
        }
    }

    private static func checkSystemAudioPackets(_ input: AVAudioPCMBuffer) async throws {
        let processor = AudioProcessor()
        processor.ingestSystemAudio(input.audioBufferList, format: input.format)
        input.floatChannelData![0].update(repeating: 0, count: Int(input.frameLength))
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
            Caption(recordingStartSeconds: 0, original: "First\nline", translation: "第一段", originalFinal: true, translationFinal: true),
            Caption(recordingStartSeconds: 3661, original: "Second", translation: "断开的草稿", originalFinal: true),
            Caption(original: "Unfinished raw transcript", translation: ""),
        ]
        let exported = TextExport.render(results)
        precondition(exported == "[00:00:00] First line\n第一段\n\n[01:01:01] Second\n[翻译未完成]\n")
        precondition(String(data: Data(exported.utf8), encoding: .utf8) == exported)
        precondition(TextExport.render([]).isEmpty)

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sameTime = Date(timeIntervalSince1970: 0)
        let first = try TextExport.saveAutomatically(exported, to: .init(folder: folder, createFolder: true, name: SessionExport.name(at: sameTime)))
        let second = try TextExport.saveAutomatically("另一节课\n", to: .init(folder: folder, createFolder: false, name: SessionExport.name(at: sameTime)))
        let firstText = try String(contentsOf: first, encoding: .utf8)
        let secondText = try String(contentsOf: second, encoding: .utf8)
        precondition(first != second && first.pathExtension == "txt")
        precondition(firstText == exported && secondText == "另一节课\n")
        let unavailable = folder.appending(path: "disconnected-folder", directoryHint: .isDirectory)
        let write = try? TextExport.saveAutomatically(exported, to: .init(folder: unavailable, createFolder: false, name: SessionExport.name()))
        precondition(write == nil && !FileManager.default.fileExists(atPath: unavailable.path))
    }

    private static func checkPrivateDataLocation() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = folder.appending(path: "source", directoryHint: .isDirectory)
        let worktree = folder.appending(path: "worktree", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: repo.appending(path: ".git", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data().write(to: worktree.appending(path: ".git"))
        let link = folder.appending(path: "linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: repo)
        let linkedFile = folder.appending(path: "linked.txt")
        let repoFile = repo.appending(path: "notes.txt")
        try Data().write(to: repoFile)
        try fm.createSymbolicLink(at: linkedFile, withDestinationURL: repoFile)

        func denied(_ action: () throws -> Void) throws {
            do {
                try action()
                preconditionFailure("Private data destination inside Git was accepted")
            } catch AppFailure.privateDataInRepository {}
        }

        try PrivateDataLocation.check(folder.appending(path: "private/output"))
        for destination in [repo, worktree, link] {
            let nested = destination.appending(path: "output", directoryHint: .isDirectory)
            try denied { try SessionExport.prepare(folder: nested, createFolder: true) }
            precondition(!fm.fileExists(atPath: nested.path))
        }
        try denied { try PrivateDataLocation.check(linkedFile) }
        try denied {
            try APIKeyStore(folder: repo.appending(path: "keys")).save(
                "test-only", role: .transcription, endpoint: APIEndpoint(""))
        }
        precondition(!fm.fileExists(atPath: repo.appending(path: "keys").path))
        try denied {
            _ = try ExportArchive.saveCopy(text: "fixture", audio: nil,
                                            to: SessionExport(folder: worktree, createFolder: false, name: "session"))
        }
    }

    private static func checkExportArchive() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let old = SessionExport(folder: folder, createFolder: false, name: SessionExport.name())
        let recent = SessionExport(folder: folder, createFolder: false, name: SessionExport.name())
        let now = Date()
        let expired = now.addingTimeInterval(-2 * 86_400)
        for record in [old, recent] {
            for ext in ["mp3", "txt"] {
                let file = record.fileURL(endingIn: ext)
                try "test".write(to: file, atomically: true, encoding: .utf8)
                let date = record.name == recent.name && ext == "mp3" ? now : expired
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            }
        }
        let copyName = folder.appending(path: "我的课堂.txt")
        let copy = SessionExport(savePanelURL: copyName)
        precondition(copy.name == "我的课堂")
        let copied = try ExportArchive.saveCopy(text: "字幕", audio: old.fileURL(endingIn: "mp3"), to: copy)
        precondition(Set(copied) == Set([copyName, folder.appending(path: "我的课堂.mp3")]))
        let collision = try? ExportArchive.saveCopy(text: "新字幕", audio: nil, to: copy)
        let original = try String(contentsOf: copyName, encoding: .utf8)
        precondition(collision == nil && original == "字幕")
        for file in copied { try fm.setAttributes([.modificationDate: expired], ofItemAtPath: file.path) }
        try ExportArchive.removeExpired(in: folder, after: 0, now: now)
        precondition(fm.fileExists(atPath: old.fileURL(endingIn: "mp3").path))
        try ExportArchive.removeExpired(in: folder, after: 1, now: now)
        for ext in ["mp3", "txt"] {
            precondition(!fm.fileExists(atPath: old.fileURL(endingIn: ext).path))
            precondition(fm.fileExists(atPath: recent.fileURL(endingIn: ext).path))
            precondition(fm.fileExists(atPath: copy.fileURL(endingIn: ext).path))
        }
    }

    private static func checkSessionRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let folder = root.appendingPathComponent("output")
        let encoder = URL(fileURLWithPath: CommandLine.arguments[1])
        let recording = SessionRecording(stagingFolder: staging, encoder: encoder)
        let destination = SessionExport(folder: folder, createFolder: true, name: recording.name)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

        func capture(_ sample: Int16, frames: AVAudioFrameCount = 9_600,
                     using recording: SessionRecording) async throws -> [QueuedAudioEvent] {
            let processor = AudioProcessor(recording: recording)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            pcm.frameLength = frames
            let samples = pcm.int16ChannelData![0]
            for index in 0..<Int(pcm.frameLength) { samples[index] = index % 20 < 10 ? sample : -sample }
            processor.copyFromTap(pcm)
            processor.finish()
            var packets: [QueuedAudioEvent] = []
            for try await packet in processor.events { packets.append(packet) }
            return packets
        }

        // Two captures model pause and resume. The recording includes audio before the speech gate.
        let silentPackets = try await capture(0, frames: 28_800, using: recording)
        let speechPackets = try await capture(1200, using: recording)
        precondition(silentPackets.isEmpty)
        precondition(speechPackets.compactMap(\.recordingStartSeconds) == [1])
        let outcome = await recording.finish(to: destination)
        guard let url = outcome.url, outcome.warning == nil else { preconditionFailure("Recording did not save") }
        let caption = Caption(recordingStartSeconds: speechPackets.first?.recordingStartSeconds,
                              original: "Hello.", translation: "你好。", originalFinal: true, translationFinal: true)
        let content = TextExport.render([caption])
        precondition(content == "[00:00:01] Hello.\n你好。\n")
        let text = try TextExport.saveAutomatically(content, to: destination)
        precondition(url.pathExtension == "mp3" && url.deletingPathExtension() == text.deletingPathExtension())
        let recorded = try AVAudioFile(forReading: url)
        precondition(recorded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3)
        precondition(abs(Double(recorded.length) / recorded.fileFormat.sampleRate - 1.6) < 0.1)

        let recovery = SessionRecording(stagingFolder: staging, encoder: encoder)
        _ = try await capture(1200, using: recovery)
        let fallback = await recovery.finish(to: .init(folder: root.appendingPathComponent("missing"),
                                                       createFolder: false, name: recovery.name))
        precondition(fallback.url?.pathExtension == "mp3")
        precondition(fallback.url?.deletingLastPathComponent().path == staging.path && fallback.warning != nil)
        let retained = try AVAudioFile(forReading: fallback.url!)
        precondition(retained.length > 0)

        let missingEncoder = SessionRecording(stagingFolder: staging, encoder: nil)
        _ = try await capture(1200, using: missingEncoder)
        let wav = await missingEncoder.finish(to: .init(folder: folder, createFolder: false, name: missingEncoder.name))
        precondition(wav.url?.pathExtension == "wav" && wav.warning?.contains("MP3 编码失败") == true)
        let backup = try AVAudioFile(forReading: wav.url!)
        precondition(backup.length > 0)

        let skipped = SessionRecording(stagingFolder: staging, encoder: encoder)
        _ = try await capture(1200, using: skipped)
        await skipped.discard()
        let discarded = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        precondition(!discarded.contains { $0.hasPrefix(skipped.name) })

        let manual = SessionRecording(stagingFolder: staging, encoder: encoder)
        _ = try await capture(1200, using: manual)
        let staged = await manual.finish(to: nil)
        guard let audio = staged.url else { preconditionFailure("Expected a staged manual recording") }
        let manualFiles = try ExportArchive.saveCopy(text: content, audio: audio,
                                                      to: .init(folder: folder, createFolder: false, name: "手动另存"))
        await manual.discard()
        precondition(!FileManager.default.fileExists(atPath: audio.path) && manualFiles.count == 2)
        precondition(manualFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
