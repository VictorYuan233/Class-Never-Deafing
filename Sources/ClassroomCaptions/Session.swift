import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class ClassroomSession: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, starting, listening, pausing, paused, reconnecting, stopping
    }

    private struct SegmentAudio {
        let pcm: Data
        let source: Language
    }

    private struct SubmittedSegment {
        let boundary: SpeechBoundary
        let committedAt = ContinuousClock.now
        var audio: SegmentAudio?
    }

    private struct Recovery {
        let id: UUID
        let audio: SegmentAudio
        let partial: String
        let omitIfEmpty: Bool
    }

    private struct TranslationJob {
        let id: UUID
        let enqueuedAt = ContinuousClock.now
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "准备就绪"
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var liveDrafts = TranscriptDrafts.Snapshot()
    @Published private(set) var notice: String?
    @Published private(set) var recordingClock = RecordingClock()
    @Published private(set) var automaticExportURL: URL?
    @Published private(set) var automaticRecordingURL: URL?
    @Published private(set) var hasError = false
    var exportFolder: URL?

    private var drafts = TranscriptDrafts()
    private var indices: [UUID: Int] = [:]
    private var submitted: [UUID: SubmittedSegment] = [:]
    private var recoveryQueue: [Recovery] = []
    private var recoveryWorkers: [UUID: Task<Void, Never>] = [:]
    private var translationDeltas: [UUID: String] = [:]
    private var originalRefresh: Task<Void, Never>?
    private var translationRefresh: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var translationQueue: [TranslationJob] = []
    private var sessionTask: Task<Void, Never>?
    private var stopDeadline: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var rotationSource: Language?
    private var retirements: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: RealtimeConnection] = [:]
    private var capture: AudioCapture?
    private var active: RealtimeConnection?
    private var replacement: RealtimeConnection?
    private var source = Language.automatic
    private var target = Language.simplified
    private var audioInputID = AudioInput.defaultID
    private var transcriptionModel = TranscriptionModel.live
    private var translationModel = TranslationConfiguration.defaultModel
    private var segmentationLength = SegmentationLength.standard
    private var key: String?
    private var inputChanged = false
    private var resumeSignal: CheckedContinuation<Void, Never>?
    private var silencePauseMinutes: Int?
    private var silenceTask: Task<Void, Never>?
    private var pausedForSilence = false

    var canExport: Bool {
        phase == .idle && captions.contains { $0.originalFinal && !$0.original.isEmpty }
    }

    var savedFiles: [URL] { [automaticExportURL, automaticRecordingURL].compactMap { $0 } }

    func start(
        source: Language, target: Language, transcription: TranscriptionModel, translation: TranslationConfiguration,
        audioInputID: String, segmentationLength: SegmentationLength,
        authorize: @escaping @MainActor () async throws -> String?
    ) {
        guard phase == .idle else { return }
        AppLog.event("session.start.requested")
        AppLog.event("session.segmentation", number: segmentationLength.rawValue)
        phase = .authorizing
        status = "正在读取钥匙串…"
        notice = nil
        hasError = false
        self.source = source
        self.target = target
        sessionTask = Task {
            do {
                let key = try await authorize()
                try Task.checkCancellation()
                guard let key else {
                    status = "准备就绪"
                    phase = .idle
                    sessionTask = nil
                    return
                }
                prepare(transcription: transcription, translation: translation, audioInputID: audioInputID,
                        segmentationLength: segmentationLength, key: key)
                await run(recording: SessionRecording())
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.failure("session.authorization.failed", error)
                status = description(for: error)
                notice = status
                hasError = true
                phase = .idle
                sessionTask = nil
            }
        }
    }

    private func prepare(
        transcription: TranscriptionModel,
        translation: TranslationConfiguration, audioInputID: String, segmentationLength: SegmentationLength, key: String
    ) {
        cancelTranslations()
        captions.removeAll()
        indices.removeAll()
        drafts = TranscriptDrafts()
        submitted.removeAll()
        originalRefresh?.cancel()
        originalRefresh = nil
        liveDrafts = TranscriptDrafts.Snapshot()
        notice = nil
        recordingClock = RecordingClock()
        automaticExportURL = nil
        automaticRecordingURL = nil
        self.audioInputID = audioInputID
        self.segmentationLength = segmentationLength
        transcriptionModel = transcription
        translationModel = translation
        self.key = key
        phase = .starting
        status = "正在准备音频输入…"
    }

    func selectSource(_ language: Language) {
        guard source != language else { return }
        source = language
        if phase == .listening, let key {
            cancelRotation()
            let delay: Duration = active?.configuredSource == source ? .seconds(55 * 60) : .zero
            scheduleRotation(key: key, delay: delay)
        }
    }

    func selectTarget(_ language: Language) {
        target = language
    }

    func configureSilencePause(minutes: Int?) {
        guard silencePauseMinutes != minutes else { return }
        silencePauseMinutes = minutes
        armSilencePause()
    }

    private func armSilencePause() {
        cancelSilencePause()
        guard phase == .listening, let capture, let silencePauseMinutes else { return }
        let clock = SuspendingClock()
        let startedAt = clock.now
        let timeout = Duration.seconds(silencePauseMinutes * 60)
        silenceTask = Task { [weak self, weak capture] in
            while !Task.isCancelled {
                guard let capture else { return }
                let lastHeardAt = max(capture.lastHeardAt ?? startedAt, startedAt)
                let deadline = lastHeardAt.advanced(by: timeout)
                if clock.now >= deadline {
                    guard let self, self.capture === capture else { return }
                    self.pause(afterSilence: true)
                    return
                }
                do { try await clock.sleep(until: deadline) }
                catch { return }
            }
        }
    }

    private func cancelSilencePause() {
        silenceTask?.cancel()
        silenceTask = nil
    }

    func pause(afterSilence: Bool = false) {
        guard phase == .listening else { return }
        AppLog.event(afterSilence ? "session.pause.silence" : "session.pause")
        pausedForSilence = afterSilence
        cancelSilencePause()
        recordingClock.pause()
        phase = .pausing
        status = "正在暂停…"
        capture?.stop()
        cancelRotation()
    }

    func resume() {
        guard phase == .paused else { return }
        AppLog.event("session.resume")
        phase = .starting
        status = "正在继续…"
        endPauseWait()
    }

    private func endPauseWait() {
        let signal = resumeSignal
        resumeSignal = nil
        signal?.resume()
    }

    func stop() {
        guard phase != .idle, phase != .stopping else { return }
        if phase == .authorizing {
            AppLog.event("session.start.cancelled")
            sessionTask?.cancel()
            sessionTask = nil
            status = "已取消启动"
            phase = .idle
            return
        }
        AppLog.event("session.stop.requested")
        cancelSilencePause()
        let wasListening = phase == .listening || phase == .pausing
        recordingClock.pause()
        phase = .stopping
        status = "正在收尾…"
        capture?.stop()
        rotation?.cancel()
        endPauseWait()
        if !wasListening { active?.close() }
        stopDeadline = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, phase == .stopping else { return }
            AppLog.event("session.stop.drain_timeout")
            closeAll()
        }
    }

    func retryTranslation(_ id: UUID) {
        guard workers[id] == nil, !translationQueue.contains(where: { $0.id == id }), let index = indices[id],
              captions[index].translationFailed else { return }
        Task {
            do {
                let credential: String?
                if let key { credential = key } else { credential = try await KeyStore.read() }
                guard workers[id] == nil, !translationQueue.contains(where: { $0.id == id }), let index = indices[id],
                      captions[index].translationFailed else { return }
                guard let credential else {
                    notice = "请先在设置中保存 OpenAI API Key。"
                    return
                }
                translationQueue.append(TranslationJob(id: id))
                startQueuedTranslations(using: credential)
            } catch {
                if indices[id] != nil { notice = error.localizedDescription }
            }
        }
    }

    private func run(recording: SessionRecording) async {
        await listen(recording: recording)
        let destination = SessionExport(folder: exportFolder ?? TextExport.automaticFolder,
                                        createFolder: exportFolder == nil, name: recording.name)
        let audio = await recording.finish(to: destination)
        automaticRecordingURL = audio.url
        await drainResults()
        finishSession(destination: destination, recordingWarning: audio.warning)
    }

    private func listen(recording: SessionRecording) async {
        guard let key, phase != .stopping else { return }
        var attempts = 0

        while phase != .stopping, !Task.isCancelled {
            if phase == .paused {
                await withCheckedContinuation { resumeSignal = $0 }
                continue
            }
            let connection = makeConnection(key)
            active = connection
            inputChanged = false
            var listeningSince: Date?
            do {
                status = attempts == 0 ? "正在连接 OpenAI…" : "正在重连（\(attempts)/3）…"
                AppLog.event("session.connection.begin", number: attempts)
                try await connection.connect(source: source, model: transcriptionModel)
                AppLog.event("session.connection.ready")
                guard phase != .stopping else { break }
                let input = AudioCapture(inputID: audioInputID, length: segmentationLength, recording: recording)
                capture = input
                status = "正在启动音频输入…"
                let audio = try await input.start()
                guard phase != .stopping else { break }
                recordingClock.resume()
                phase = .listening
                AppLog.event("session.listening")
                listeningSince = Date()
                status = "正在监听"
                armSilencePause()
                let delay: Duration = connection.configuredSource == source ? .seconds(55 * 60) : .zero
                scheduleRotation(key: key, delay: delay)
                try await upload(audio, tracking: input)
                cancelSilencePause()
                await input.stopAndDrain()
                capture = nil
                recordingClock.pause()
                if phase == .stopping { break }
                if phase == .pausing {
                    finishPause()
                    attempts = 0
                    continue
                }

                if inputChanged {
                    if let active { retire(active) }
                    cancelRotation()
                    active = nil
                    notice = "音频设备发生变化，正在重新采音。"
                    phase = .reconnecting
                    attempts = 0
                    continue
                }

                if let failure = active?.failure { throw failure }
                throw AppFailure.microphone
            } catch {
                cancelSilencePause()
                await capture?.stopAndDrain()
                capture = nil
                recordingClock.pause()
                cancelRotation()
                if phase == .stopping { break }
                if phase == .pausing {
                    notice = "暂停前的部分音频未能完成转写。"
                    finishPause()
                    attempts = 0
                    continue
                }
                let error = active?.failure ?? error
                AppLog.failure("session.failed", error)
                if let listeningSince, Date().timeIntervalSince(listeningSince) >= 30 {
                    attempts = 0
                }
                if let active {
                    remove(active)
                }
                active = nil
                if !recoverable(error) || attempts >= 3 {
                    status = description(for: error)
                    notice = status
                    hasError = true
                    break
                }
                if phase == .listening {
                    notice = "连接中断，部分音频可能缺失。"
                }
                phase = .reconnecting
                attempts += 1
                status = "正在重连（\(attempts)/3）…"
                try? await Task.sleep(for: .seconds(1 << (attempts - 1)))
            }
        }

        await capture?.stopAndDrain()
        capture = nil
    }

    private func drainResults() async {
        while connections.values.contains(where: \.outstanding) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        stopDeadline?.cancel()
        stopDeadline = nil

        while !recoveryWorkers.isEmpty || !recoveryQueue.isEmpty || !workers.isEmpty || !translationQueue.isEmpty {
            if Task.isCancelled { break }
            if phase == .stopping {
                let pendingRecovery = !recoveryWorkers.isEmpty || !recoveryQueue.isEmpty
                let message = pendingRecovery ? "正在补识别剩余音频…" : "正在补齐译文…"
                if status != message { status = message }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishPause() {
        if let active { retire(active) }
        active = nil
        publishOriginal()
        phase = .paused
        status = pausedForSilence ? "无声超时，已自动暂停" : "已暂停"
    }

    private func upload(_ audio: AudioEvents, tracking input: AudioCapture) async throws {
        let inputID = ObjectIdentifier(input)
        let observer = input.engine.map { engine in
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let capture = self.capture,
                          ObjectIdentifier(capture) == inputID, self.phase == .listening else { return }
                    self.inputChanged = true
                    self.recordingClock.pause()
                    capture.stop()
                }
            }
        }
        defer { if let observer { NotificationCenter.default.removeObserver(observer) } }
        var segment: UUID?
        var pcm = Data()
        var sentFirstPacket = false
        do {
            for try await packet in audio {
                switch packet.event {
                case .audio(let data):
                    if segment == nil {
                        await switchSourceAtBoundary()
                        let caption = Caption()
                        indices[caption.id] = captions.count
                        captions.append(caption)
                        segment = caption.id
                    }
                    guard let active else { return }
                    if transcriptionModel == .live { pcm.append(data) }
                    if !sentFirstPacket {
                        sentFirstPacket = true
                        AppLog.latency("audio.first_packet_queue_ms", since: packet.queuedAt)
                    }
                    try await active.append(data)
                case .commit(let boundary):
                    if let id = segment, let active {
                        if let index = indices[id] { captions[index].translationLanguage = target }
                        let audio = pcm.isEmpty ? nil : SegmentAudio(pcm: pcm, source: active.configuredSource ?? source)
                        rememberSubmission(id, boundary: boundary, audio: audio)
                        pcm = Data()
                        AppLog.event("audio.boundary_pause_ms", number: boundary.silentFrames * 20)
                        AppLog.latency("audio.commit_queue_ms", since: packet.queuedAt)
                        try await active.commit(id)
                        segment = nil
                    }
                }
            }
        } catch {
            if let segment { apply(.failed(segment)) }
            throw error
        }
        if let segment { apply(.failed(segment)) }
    }

    private func switchSourceAtBoundary() async {
        guard phase == .listening, let current = active, let key else { return }
        if current.configuredSource != source, replacement?.configuredSource != source {
            if rotationSource != source {
                cancelRotation()
                scheduleRotation(key: key, delay: .zero)
            }
            await rotation?.value
        }
        guard phase == .listening, let next = replacement, next.failure == nil,
              next.configuredSource == source else { return }
        replacement = nil
        active = next
        retire(current)
        scheduleRotation(key: key, delay: .seconds(55 * 60))
    }

    private func makeConnection(_ credential: String) -> RealtimeConnection {
        let connection = RealtimeConnection(key: credential) { [weak self] event in
            self?.apply(event)
        } onDisconnect: { [weak self] id, _ in
            guard let self else { return }
            if self.active?.id == id {
                self.recordingClock.pause()
                self.capture?.stop()
            } else if let connection = self.connections[id] {
                let wasReplacement = self.replacement?.id == id
                self.remove(connection)
                if wasReplacement {
                    self.replacement = nil
                    if self.phase == .listening, let key = self.key {
                        self.scheduleRotation(key: key, delay: .seconds(10))
                    }
                }
            }
        }
        connections[connection.id] = connection
        return connection
    }

    private func scheduleRotation(key: String, delay: Duration) {
        rotation?.cancel()
        let requestedSource = source
        rotationSource = requestedSource
        rotation = Task {
            do {
                try await Task.sleep(for: delay)
                guard phase == .listening else { return }
                let next = makeConnection(key)
                do {
                    try await next.connect(source: requestedSource, model: transcriptionModel)
                    try Task.checkCancellation()
                    guard phase == .listening else {
                        remove(next)
                        return
                    }
                    replacement = next
                } catch {
                    remove(next)
                    if !Task.isCancelled, phase == .listening {
                        if active?.configuredSource != source {
                            notice = "源语言暂未切换，将在下一段重试。"
                        }
                        scheduleRotation(key: key, delay: .seconds(10))
                    }
                }
            } catch { return }
        }
    }

    private func cancelRotation() {
        rotation?.cancel()
        rotation = nil
        rotationSource = nil
        if let replacement { remove(replacement) }
        replacement = nil
    }

    private func retire(_ connection: RealtimeConnection) {
        retirements[connection.id] = Task {
            for _ in 0..<150 {
                if !connection.outstanding || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled { remove(connection) }
        }
    }

    private func remove(_ connection: RealtimeConnection) {
        connection.close()
        connections.removeValue(forKey: connection.id)
        drafts.remove(connection: connection.id)
        publishOriginal()
        retirements.removeValue(forKey: connection.id)?.cancel()
    }

    private func closeAll() {
        cancelRotation()
        for connection in Array(connections.values) { remove(connection) }
        active = nil
    }

    private func finishSession(destination: SessionExport, recordingWarning: String?) {
        let stoppedByUser = phase == .stopping
        cancelSilencePause()
        recordingClock.pause()
        closeAll()
        submitted.removeAll()
        stopDeadline?.cancel()
        stopDeadline = nil
        key = nil
        sessionTask = nil
        AppLog.event("session.ended", number: Int(recordingClock.elapsed().components.seconds))
        var warnings = [recordingWarning].compactMap { $0 }
        if stoppedByUser {
            let text = TextExport.render(captions)
            if !text.isEmpty {
                do {
                    automaticExportURL = try TextExport.saveAutomatically(text, to: destination)
                    AppLog.event("export.success")
                } catch {
                    AppLog.failure("export.failed", error)
                    warnings.append("字幕自动保存失败。可在菜单栏选择「另存本节课文本」。")
                }
            }
            switch (automaticExportURL, automaticRecordingURL) {
            case (.some, .some): status = "已停止 · 字幕和录音已保存"
            case (.some, nil): status = "已停止 · 字幕已保存"
            case (nil, .some): status = "已停止 · 录音已保存"
            case (nil, nil): status = "已停止 · 没有可保存的内容"
            }
        }
        if !warnings.isEmpty {
            hasError = true
            if stoppedByUser { status = "已停止 · 保存有提示" }
            notice = ([stoppedByUser ? nil : notice].compactMap { $0 } + warnings).joined(separator: "\n")
        }
        phase = .idle
    }

    private func apply(_ event: RealtimeEvent) {
        switch event {
        case .preview(let connection, let item, let delta):
            if drafts.append(delta, connection: connection, item: item) {
                AppLog.event("transcription.preview.first")
            }
            if connection == active?.id { scheduleOriginalRefresh() }
        case .bound(let connection, let item, let segment):
            drafts.bind(connection: connection, item: item, to: segment)
            scheduleOriginalRefresh()
        case .delta(let id, let text):
            if let index = indices[id], !captions[index].originalFinal {
                if drafts.append(text, to: id), let segment = submitted[id] {
                    AppLog.latency("transcription.first_delta_after_commit_ms", since: segment.committedAt)
                }
                scheduleOriginalRefresh()
            }
        case .final(let id, let text):
            resolveRealtime(id, text: text)
        case .failed(let id):
            resolveRealtime(id, text: nil)
        }
    }

    private func resolveRealtime(_ id: UUID, text: String?) {
        guard let index = indices[id], !captions[index].originalFinal, recoveryWorkers[id] == nil,
              !recoveryQueue.contains(where: { $0.id == id }) else { return }
        defer { publishOriginal() }
        let partial = drafts.remove(id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let segment = submitted.removeValue(forKey: id)
        if let segment, text != nil {
            AppLog.latency("transcription.final_ms", since: segment.committedAt)
        }
        let original = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !original.isEmpty {
            finishOriginal(original, for: id)
            return
        }

        let omitIfEmpty = text != nil && segment?.boundary.hasSustainedSignal == false
        if text != nil {
            AppLog.event("transcription.empty", number: segment.map { $0.boundary.voicedFrames * 20 })
        } else {
            AppLog.event("transcription.failed")
        }
        if let audio = segment?.audio, let key, recoveryQueue.count + recoveryWorkers.count < 12 {
            if !partial.isEmpty { captions[index].original = partial }
            recoveryQueue.append(Recovery(id: id, audio: audio, partial: partial, omitIfEmpty: omitIfEmpty))
            startQueuedRecovery(using: key)
        } else {
            if segment?.audio != nil { AppLog.event("transcription.recovery.skipped") }
            finishOriginal(partial, for: id, omitIfEmpty: omitIfEmpty)
        }
    }

    private func rememberSubmission(_ id: UUID, boundary: SpeechBoundary, audio: SegmentAudio?) {
        // Only keep a short, bounded window in memory while waiting for Realtime.
        if audio != nil {
            let retained = submitted.filter { $0.value.audio != nil }
            if retained.count == 12,
               let oldest = retained.min(by: { $0.value.committedAt < $1.value.committedAt })?.key {
                submitted[oldest]?.audio = nil
                AppLog.event("transcription.recovery.audio_evicted")
            }
        }
        submitted[id] = SubmittedSegment(boundary: boundary, audio: audio)
    }

    private func startQueuedRecovery(using credential: String) {
        while recoveryWorkers.count < 2, !recoveryQueue.isEmpty {
            let job = recoveryQueue.removeFirst()
            recoveryWorkers[job.id] = Task {
                var original = job.partial
                var omitIfEmpty = job.omitIfEmpty
                do {
                    let recovered = try await TranscriptionRecoveryAPI.transcribe(job.audio.pcm, source: job.audio.source, key: credential)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    AppLog.event(recovered.isEmpty ? "transcription.recovery.empty" : "transcription.recovery.success")
                    if !recovered.isEmpty { original = recovered }
                } catch {
                    omitIfEmpty = false
                    AppLog.failure("transcription.recovery.failed", error)
                }
                finishOriginal(original, for: job.id, omitIfEmpty: omitIfEmpty)
                recoveryWorkers.removeValue(forKey: job.id)
                startQueuedRecovery(using: credential)
            }
        }
    }

    private func finishOriginal(_ text: String, for id: UUID, omitIfEmpty: Bool = false) {
        guard let index = indices[id], !captions[index].originalFinal else { return }
        var caption = captions[index]
        caption.original = text
        caption.originalFinal = true
        caption.originalFailed = text.isEmpty && !omitIfEmpty
        captions[index] = caption
        if text.isEmpty && omitIfEmpty { AppLog.event("transcription.empty.low_signal") }
        if !text.isEmpty, let key {
            translationQueue.append(TranslationJob(id: id))
            startQueuedTranslations(using: key)
        }
    }

    private func publishOriginal() {
        let snapshot = drafts.snapshot()
        if snapshot != liveDrafts { liveDrafts = snapshot }
    }

    private func scheduleOriginalRefresh() {
        guard originalRefresh == nil else { return }
        originalRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) }
            catch { return }
            self?.originalRefresh = nil
            self?.publishOriginal()
        }
    }

    private func scheduleTranslationRefresh() {
        guard translationRefresh == nil else { return }
        translationRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) }
            catch { return }
            self?.publishTranslations()
        }
    }

    private func publishTranslations() {
        translationRefresh = nil
        guard !translationDeltas.isEmpty else { return }
        var updated = captions
        for (id, delta) in translationDeltas {
            if let index = indices[id] { updated[index].translation += delta }
        }
        translationDeltas.removeAll(keepingCapacity: true)
        captions = updated
    }

    private func startQueuedTranslations(using credential: String) {
        while workers.count < 4, !translationQueue.isEmpty {
            let job = translationQueue.removeFirst()
            let id = job.id
            guard let index = indices[id] else { continue }
            let original = captions[index].original
            let previous = captions[..<index].last { $0.originalFinal && !$0.original.isEmpty }?.original
            let language = captions[index].translationLanguage
            let model = translationModel
            if captions[index].translationFailed {
                captions[index].translation = ""
                captions[index].translationFailed = false
            }
            workers[id] = Task {
                defer {
                    if !Task.isCancelled {
                        workers.removeValue(forKey: id)
                        startQueuedTranslations(using: credential)
                    }
                }
                do {
                    AppLog.latency("translation.queue_ms", since: job.enqueuedAt)
                    let text = try await TranslationAPI.shared.translate(original, to: language, model: model, previous: previous, key: credential) { delta in
                        if !Task.isCancelled, self.indices[id] != nil {
                            self.translationDeltas[id, default: ""] += delta
                            self.scheduleTranslationRefresh()
                        }
                    }
                    try Task.checkCancellation()
                    translationDeltas.removeValue(forKey: id)
                    if let index = indices[id] {
                        captions[index].translation = text
                        captions[index].translationFinal = true
                    }
                } catch {
                    translationDeltas.removeValue(forKey: id)
                    if !Task.isCancelled, let index = indices[id] {
                        AppLog.failure("translation.failed", error)
                        captions[index].translation = ""
                        captions[index].translationFailed = true
                        notice = description(for: error)
                    }
                }
            }
        }
    }

    private func cancelTranslations() {
        for worker in workers.values { worker.cancel() }
        workers.removeAll()
        translationQueue.removeAll()
        translationDeltas.removeAll()
        translationRefresh?.cancel()
        translationRefresh = nil
    }

    private func recoverable(_ error: Error) -> Bool {
        if let failure = error as? AppFailure { return failure.canRetry }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return false
    }

    private func description(for error: Error) -> String {
        if let failure = error as? AppFailure { return failure.localizedDescription }
        return "无法连接 OpenAI，请检查网络后重试。"
    }
}
