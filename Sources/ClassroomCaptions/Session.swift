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

    private struct TranslationContext: Equatable {
        let source: Language
        let target: Language
        let captureID: UUID?
    }

    private struct TranslationJob {
        let id: UUID
        let service: TranslationService
        let enqueuedAt = ContinuousClock.now
    }

    private struct DraftRow {
        let firstSeenAt = ContinuousClock.now
        var translation: DraftTranslation?
    }

    private struct DraftWork {
        let id = UUID()
        let position: Int
        var captionID: UUID?
        var promotedText = ""
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "准备就绪"
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var liveParagraphs: [LiveCaption] = []
    @Published private(set) var markers: [RecordingMarker] = []
    @Published private(set) var notice: String?
    @Published private(set) var recordingClock = RecordingClock()
    @Published private(set) var automaticExportURL: URL?
    @Published private(set) var automaticRecordingURL: URL?
    @Published private(set) var manualExportFiles: [URL] = []
    @Published private(set) var hasError = false
    @Published private(set) var hasArchivedCaptions = false
    @Published private(set) var historyID = UUID()
    @Published private var visibleSince: Int64 = 0
    var exportFolder: URL?
    private var chooseSaveCopy: ((String, String?) async -> SessionExport?)?

    private var drafts = TranscriptDrafts()
    private var pendingOriginals: [Caption] = []
    private var indices: [UUID: Int] = [:]
    private var nextCaptionPosition = 0
    private var transcriptArchive: TranscriptArchive?
    private var archiveTask: Task<Void, Never>?
    private var storedPositions: Set<Int> = []
    private var archiveSaved = false
    private var submitted: [UUID: SubmittedSegment] = [:]
    private var recoveryQueue: [Recovery] = []
    private var recoveryWorkers: [UUID: Task<Void, Never>] = [:]
    private var translationDeltas: [UUID: String] = [:]
    private var originalRefresh: Task<Void, Never>?
    private var translationRefresh: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var translationQueue: [TranslationJob] = []
    private var originalPreviews: [SentenceBatcher.Preview] = []
    private var draftRows: [Int: DraftRow] = [:]
    private var draftWork: DraftWork?
    private var draftTask: Task<Void, Never>?
    private var draftCheck: Task<Void, Never>?
    private var sentenceBatch = SentenceBatcher()
    private var sentenceCount = SentenceBatcher.defaultCount
    private var batchContext: TranslationContext?
    private var batchTimer: Task<Void, Never>?
    private var batchUpdatedAt = SuspendingClock().now
    private var recording: SessionRecording?
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
    private var apis: SessionAPIs?
    private var translationTuning: TranslationTuning?
    var translationForRetry: (() throws -> TranslationService)?
    private var inputChanged = false
    private var resumeSignal: CheckedContinuation<Void, Never>?
    private var silencePauseMinutes: Int?
    private var silenceTask: Task<Void, Never>?
    private var pausedForSilence = false

    var canExport: Bool {
        phase == .idle && (hasHistory || !markers.isEmpty)
    }

    var hasHistory: Bool {
        hasArchivedCaptions || captions.contains { !$0.original.isEmpty }
    }

    var visibleCaptions: [Caption] {
        return captions.filter { caption in
            let mayHide = caption.original.isEmpty || (caption.translationFinal &&
                (transcriptArchive == nil || storedPositions.contains(caption.position)))
            return !mayHide || (caption.recordingStartSeconds ?? .max) >= visibleSince
        }
    }

    var savedFiles: [URL] { manualExportFiles.isEmpty ? [automaticExportURL, automaticRecordingURL].compactMap { $0 } : manualExportFiles }
    var canStopAndSaveAs: Bool { [.listening, .pausing, .paused, .reconnecting].contains(phase) }

    func addMarker() {
        guard phase == .listening, let recording else { return }
        markers.append(RecordingMarker(number: markers.count + 1, seconds: recording.elapsedSeconds))
    }

    func configureTranslation(_ tuning: TranslationTuning?) {
        translationTuning = tuning
        if let service = apis?.translation { apis?.translation = service.applying(tuning) }
    }

    func configureSentenceCount(_ count: Int) {
        guard SentenceBatcher.counts.contains(count), sentenceCount != count else { return }
        sentenceCount = count
        AppLog.event("session.translation_sentence_count", number: count)
        if let context = batchContext {
            submitCompleteBatches(context: context)
        }
        publishOriginal()
    }

    func start(
        source: Language, target: Language,
        audioInputID: String,
        automaticSave: Bool, retentionDays: Int,
        authorize: @escaping @MainActor () async throws -> SessionAPIs?
    ) {
        guard phase == .idle else { return }
        AppLog.event("session.start.requested")
        phase = .authorizing
        status = "正在准备 API 配置…"
        notice = nil
        hasError = false
        self.source = source
        self.target = target
        sessionTask = Task {
            do {
                let apis = try await authorize()
                try Task.checkCancellation()
                guard let apis else {
                    status = "准备就绪"
                    phase = .idle
                    sessionTask = nil
                    return
                }
                let recording = automaticSave ? SessionRecording() : SessionRecording(
                    stagingFolder: FileManager.default.temporaryDirectory.appending(path: "Class Never Deafing"))
                prepare(apis: apis, audioInputID: audioInputID)
                self.recording = recording
                if automaticSave { transcriptArchive = TranscriptArchive(name: recording.name) }
                startArchiveTimer()
                await run(recording: recording, automaticSave: automaticSave, retentionDays: retentionDays)
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

    private func prepare(apis: SessionAPIs, audioInputID: String) {
        cancelTranslations()
        discardSavedArchive()
        transcriptArchive = nil
        hasArchivedCaptions = false
        historyID = UUID()
        visibleSince = 0
        archiveSaved = false
        storedPositions.removeAll()
        nextCaptionPosition = 0
        captions.removeAll()
        pendingOriginals.removeAll()
        markers.removeAll()
        liveParagraphs = []
        sentenceBatch = .init()
        batchContext = nil
        indices.removeAll()
        drafts = TranscriptDrafts()
        submitted.removeAll()
        originalRefresh?.cancel()
        originalRefresh = nil
        notice = nil
        recordingClock = RecordingClock()
        automaticExportURL = nil
        automaticRecordingURL = nil
        manualExportFiles = []
        chooseSaveCopy = nil
        self.audioInputID = audioInputID
        self.apis = apis
        self.apis?.translation = apis.translation.applying(translationTuning)
        phase = .starting
        status = "正在准备音频输入…"
    }

    func selectSource(_ language: Language) {
        guard source != language else { return }
        source = language
        if phase == .listening, let api = apis?.transcription, api.selection != .custom {
            cancelRotation()
            let delay: Duration = active?.configuredSource == source ? .seconds(55 * 60) : .zero
            scheduleRotation(api: api, delay: delay)
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

    func stop(chooseCopy: ((String, String?) async -> SessionExport?)? = nil) {
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
        chooseSaveCopy = chooseCopy
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
        do {
            guard let service = try apis?.translation ?? translationForRetry?() else { return }
            translationQueue.append(TranslationJob(id: id, service: service))
            startQueuedTranslations()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func run(recording: SessionRecording, automaticSave: Bool, retentionDays: Int) async {
        await listen(recording: recording)
        let stoppedByUser = phase == .stopping
        let destination = automaticSave ? SessionExport(folder: exportFolder ?? TextExport.automaticFolder,
                                                        createFolder: exportFolder == nil, name: recording.name) : nil
        let audio: SessionRecording.Outcome
        if automaticSave || chooseSaveCopy != nil {
            audio = await recording.finish(to: destination)
            if automaticSave { automaticRecordingURL = audio.url }
        } else {
            await recording.discard()
            audio = .init()
        }
        await drainResults()
        archiveTask?.cancel()
        await archiveTask?.value
        archiveTask = nil
        await persistCaptions(evictOld: false)
        updateVisibleRange()
        var warnings = [audio.warning].compactMap { $0 }
        let text: String
        do { text = try await completeTranscript().value }
        catch {
            AppLog.failure("transcript.archive.read_failed", error)
            warnings.append("归档读取失败，已保留归档和当前字幕。可重试从菜单栏另存本节课文本。")
            text = ""
        }
        if let destination, stoppedByUser, !text.isEmpty {
            do {
                automaticExportURL = try TextExport.saveAutomatically(text, to: destination)
                archiveSaved = true
                AppLog.event("export.success")
            } catch {
                AppLog.failure("export.failed", error)
                warnings.append("字幕自动保存失败。可在菜单栏选择「另存本节课文本」。")
            }
        }
        if let chooseSaveCopy, audio.url != nil || !text.isEmpty {
            let name = recording.name.replacingOccurrences(of: "课堂字幕-", with: "课堂记录-")
            var failure: String?
            status = "请选择另存位置…"
            while let copy = await chooseSaveCopy(name, failure) {
                status = "正在另存录音和字幕…"
                do {
                    manualExportFiles = try await Task.detached(priority: .utility) {
                        try ExportArchive.saveCopy(text: text, audio: audio.url, to: copy)
                    }.value
                    if !text.isEmpty { archiveSaved = true }
                    break
                } catch {
                    AppLog.failure("export.copy.failed", error)
                    failure = error.localizedDescription
                }
            }
        }
        if !automaticSave { await recording.discard() }
        if let destination, stoppedByUser, retentionDays > 0,
           automaticExportURL != nil || automaticRecordingURL?.deletingLastPathComponent().standardizedFileURL == destination.folder.standardizedFileURL {
            do {
                try await Task.detached(priority: .utility) {
                    try ExportArchive.removeExpired(in: destination.folder, after: retentionDays)
                }.value
            } catch {
                AppLog.failure("export.retention.failed", error)
                warnings.append("部分过期记录未能删除。")
            }
        }
        finishSession(stoppedByUser: stoppedByUser, automaticSave: automaticSave, warnings: warnings)
    }

    private func listen(recording: SessionRecording) async {
        guard let api = apis?.transcription, phase != .stopping else { return }
        var attempts = 0

        while phase != .stopping, !Task.isCancelled {
            if phase == .paused {
                await withCheckedContinuation { resumeSignal = $0 }
                continue
            }
            let connection = api.selection == .custom ? nil : makeConnection(api.connection)
            active = connection
            inputChanged = false
            var listeningSince: Date?
            do {
                if let connection {
                    status = attempts == 0 ? "正在连接转写 API…" : "正在重连（\(attempts)/3）…"
                    AppLog.event("session.connection.begin", number: attempts)
                    try await connection.connect(source: source, model: api.selection)
                    AppLog.event("session.connection.ready")
                }
                guard phase != .stopping else { break }
                let input = AudioCapture(inputID: audioInputID, length: .standard, recording: recording)
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
                if let connection {
                    let delay: Duration = connection.configuredSource == source ? .seconds(55 * 60) : .zero
                    scheduleRotation(api: api, delay: delay)
                }
                try await upload(audio, tracking: input, service: api)
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

        for id in pendingOriginals.filter({ !$0.originalFinal }).map(\.id) {
            resolveRealtime(id, text: nil)
        }
        while !recoveryWorkers.isEmpty || !recoveryQueue.isEmpty || !workers.isEmpty ||
                !translationQueue.isEmpty || !sentenceBatch.text.isEmpty || draftWork?.captionID != nil {
            if Task.isCancelled { break }
            if recoveryWorkers.isEmpty && recoveryQueue.isEmpty && !sentenceBatch.text.isEmpty {
                flushSentenceBatch()
                publishOriginal()
            }
            if phase == .stopping {
                let pendingRecovery = !recoveryWorkers.isEmpty || !recoveryQueue.isEmpty
                let message = pendingRecovery ? "正在处理剩余音频…" : "正在补齐译文…"
                if status != message { status = message }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishPause() {
        if let active { retire(active) }
        active = nil
        if pendingOriginals.isEmpty { flushSentenceBatch() }
        phase = .paused
        publishOriginal()
        status = pausedForSilence ? "无声超时，已自动暂停" : "已暂停"
    }

    private func upload(_ audio: AudioEvents, tracking input: AudioCapture, service: TranscriptionService) async throws {
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
        let captureID = UUID()
        var segment: UUID?
        var segmentSource = source
        var pcm = Data()
        var sentFirstPacket = false
        do {
            for try await packet in audio {
                switch packet.event {
                case .audio(let data):
                    if segment == nil {
                        if service.selection != .custom { await switchSourceAtBoundary() }
                        segmentSource = active?.configuredSource ?? source
                        let caption = Caption(recordingStartSeconds: packet.recordingSeconds, translationLanguage: target,
                                              originalLanguage: segmentSource, captureID: captureID)
                        pendingOriginals.append(caption)
                        segment = caption.id
                    }
                    if service.selection != .committed { pcm.append(data) }
                    if !sentFirstPacket {
                        sentFirstPacket = true
                        AppLog.latency("audio.first_packet_queue_ms", since: packet.queuedAt)
                    }
                    if let active { try await active.append(data) }
                case .commit(let boundary):
                    if let id = segment {
                        if let index = pendingIndex(id) { pendingOriginals[index].translationLanguage = target }
                        let audio = pcm.isEmpty ? nil : SegmentAudio(pcm: pcm, source: segmentSource)
                        rememberSubmission(id, boundary: boundary, audio: audio)
                        pcm = Data()
                        AppLog.event("audio.boundary_pause_ms", number: boundary.silentFrames * 20)
                        AppLog.latency("audio.commit_queue_ms", since: packet.queuedAt)
                        if let active {
                            try await active.commit(id)
                        } else {
                            resolveRealtime(id, text: nil)
                        }
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
        guard phase == .listening, let current = active, let api = apis?.transcription else { return }
        if current.configuredSource != source, replacement?.configuredSource != source {
            if rotationSource != source {
                cancelRotation()
                scheduleRotation(api: api, delay: .zero)
            }
            await rotation?.value
        }
        guard phase == .listening, let next = replacement, next.failure == nil,
              next.configuredSource == source else { return }
        replacement = nil
        active = next
        retire(current)
        scheduleRotation(api: api, delay: .seconds(55 * 60))
    }

    private func makeConnection(_ api: APIConnection) -> RealtimeConnection {
        let connection = RealtimeConnection(api: api) { [weak self] event in
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
                    if self.phase == .listening, let api = self.apis?.transcription {
                        self.scheduleRotation(api: api, delay: .seconds(10))
                    }
                }
            }
        }
        connections[connection.id] = connection
        return connection
    }

    private func scheduleRotation(api: TranscriptionService, delay: Duration) {
        rotation?.cancel()
        let requestedSource = source
        rotationSource = requestedSource
        rotation = Task {
            do {
                try await Task.sleep(for: delay)
                guard phase == .listening else { return }
                let next = makeConnection(api.connection)
                do {
                    try await next.connect(source: requestedSource, model: api.selection)
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
                        scheduleRotation(api: api, delay: .seconds(10))
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

    private func finishSession(stoppedByUser: Bool, automaticSave: Bool, warnings: [String]) {
        cancelSilencePause()
        recordingClock.pause()
        closeAll()
        cancelDraftTranslation()
        cancelDraftCheck()
        submitted.removeAll()
        stopDeadline?.cancel()
        stopDeadline = nil
        apis = nil
        recording = nil
        chooseSaveCopy = nil
        sessionTask = nil
        AppLog.event("session.ended", number: Int(recordingClock.elapsed().components.seconds))
        if stoppedByUser {
            switch (automaticExportURL, automaticRecordingURL) {
            case (.some, .some): status = "已停止 · 字幕和录音已保存"
            case (.some, nil): status = "已停止 · 字幕已保存"
            case (nil, .some): status = "已停止 · 录音已保存"
            case (nil, nil): status = automaticSave ? "已停止 · 没有可保存的内容" : "已停止 · 自动保存已关闭"
            }
            if !manualExportFiles.isEmpty { status = "已停止 · 已另存" }
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
            if let index = pendingIndex(id), !pendingOriginals[index].originalFinal {
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
        guard let index = pendingIndex(id), !pendingOriginals[index].originalFinal, recoveryWorkers[id] == nil,
              !recoveryQueue.contains(where: { $0.id == id }) else { return }
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

        let service = apis?.transcription
        let usesHTTP = service?.selection == .custom
        let omitIfEmpty = (text != nil || usesHTTP) && segment?.boundary.hasSustainedSignal == false
        if usesHTTP {
            AppLog.event("transcription.segment.submitted")
        } else if text != nil {
            AppLog.event("transcription.empty", number: segment.map { $0.boundary.voicedFrames * 20 })
        } else {
            AppLog.event("transcription.failed")
        }
        if let audio = segment?.audio, let service, recoveryQueue.count + recoveryWorkers.count < 12 {
            if !partial.isEmpty { pendingOriginals[index].original = partial }
            recoveryQueue.append(Recovery(id: id, audio: audio, partial: partial, omitIfEmpty: omitIfEmpty))
            startQueuedRecovery(using: service)
            publishOriginal()
        } else {
            if segment?.audio != nil {
                AppLog.event("transcription.recovery.skipped")
                if usesHTTP { notice = "转写 API 处理跟不上，部分音频未能转写。录音仍会保存。" }
            }
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

    private func startQueuedRecovery(using service: TranscriptionService) {
        let usesHTTP = service.selection == .custom
        let model = usesHTTP ? service.modelID : TranscriptionModel.committed.rawValue
        while recoveryWorkers.count < 2, !recoveryQueue.isEmpty {
            let job = recoveryQueue.removeFirst()
            recoveryWorkers[job.id] = Task {
                var original = job.partial
                var omitIfEmpty = job.omitIfEmpty
                do {
                    let recovered = try await TranscriptionRecoveryAPI.transcribe(job.audio.pcm, source: job.audio.source,
                                                                                   api: service.connection, model: model)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    AppLog.event(recovered.isEmpty ? "transcription.recovery.empty" : "transcription.recovery.success")
                    if !recovered.isEmpty { original = recovered }
                } catch {
                    omitIfEmpty = false
                    AppLog.failure("transcription.recovery.failed", error)
                    if usesHTTP { notice = description(for: error) }
                }
                finishOriginal(original, for: job.id, omitIfEmpty: omitIfEmpty)
                recoveryWorkers.removeValue(forKey: job.id)
                startQueuedRecovery(using: service)
            }
        }
    }

    private func pendingIndex(_ id: UUID) -> Int? {
        pendingOriginals.firstIndex { $0.id == id }
    }

    private func finishOriginal(_ text: String, for id: UUID, omitIfEmpty: Bool = false) {
        guard let index = pendingIndex(id), !pendingOriginals[index].originalFinal else { return }
        var original = pendingOriginals[index]
        original.original = text
        original.originalFinal = true
        original.originalFailed = text.isEmpty && !omitIfEmpty
        pendingOriginals[index] = original
        if text.isEmpty && omitIfEmpty { AppLog.event("transcription.empty.low_signal") }

        // Results can arrive out of order, particularly when a segment needs HTTP recovery.
        while let next = pendingOriginals.first, next.originalFinal {
            pendingOriginals.removeFirst()
            collectSentences(from: next)
        }
        if pendingOriginals.isEmpty, phase == .paused { flushSentenceBatch() }
        // Reconcile ready captions before pruning the preview rows they can reuse.
        publishOriginal()
    }

    private func collectSentences(from original: Caption) {
        if original.originalFailed {
            flushSentenceBatch()
            appendCaption(original)
            return
        }
        guard !original.original.isEmpty else { return }
        let context = TranslationContext(source: original.originalLanguage, target: original.translationLanguage,
                                         captureID: original.captureID)
        if batchContext != context { flushSentenceBatch() }
        batchContext = context
        sentenceBatch.append(original.original, at: original.recordingStartSeconds, language: context.source)
        submitCompleteBatches(context: context)
        if !sentenceBatch.text.isEmpty {
            batchUpdatedAt = SuspendingClock().now
            armBatchTimer()
        }
    }

    private func submitCompleteBatches(context: TranslationContext) {
        while let batch = sentenceBatch.take(count: sentenceCount, language: context.source) {
            submitBatch(batch, context: context)
        }
    }

    private func armBatchTimer() {
        guard batchTimer == nil else { return }
        batchTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self else { return }
                if self.finishIdleBatch() { self.batchTimer = nil; return }
            }
        }
    }

    private func finishIdleBatch() -> Bool {
        guard !sentenceBatch.text.isEmpty else { return true }
        guard pendingOriginals.isEmpty, phase != .stopping else { return false }
        let idle = (capture?.lastHeardAt ?? batchUpdatedAt).duration(to: SuspendingClock().now)
        guard phase == .paused || idle >= .seconds(5) else { return false }
        flushSentenceBatch()
        publishOriginal()
        return true
    }

    private func flushSentenceBatch() {
        batchTimer?.cancel()
        batchTimer = nil
        if let context = batchContext, let batch = sentenceBatch.flush() { submitBatch(batch, context: context) }
        batchContext = nil
    }

    private func submitBatch(_ batch: SentenceBatcher.Batch, context: TranslationContext) {
        var caption = Caption(recordingStartSeconds: batch.startSeconds, original: batch.text,
                              originalFinal: true, translationLanguage: context.target, originalLanguage: context.source)
        let position = nextCaptionPosition
        let draft = draftRows.removeValue(forKey: position)?.translation
        let activeDraft = draftWork?.position == position && draftWork?.captionID == nil
        let matches = draft?.matches(batch.text, target: context.target) == true
        if let draft, draft.coversStart(of: batch.text, target: context.target) {
            caption.translation = draft.displayedText
            caption.translationFinal = matches && draft.completed
            caption.translationIsDraft = !caption.translationFinal && !caption.translation.isEmpty
        }
        if activeDraft {
            if matches {
                draftWork?.captionID = caption.id
                draftWork?.promotedText = draft?.text ?? ""
                caption.translationIsDraft = true
            } else {
                cancelDraftTranslation()
            }
        }
        appendCaption(caption)
        if !caption.translationFinal, draftWork?.captionID != caption.id { queueTranslation(caption.id) }
    }

    private func appendCaption(_ original: Caption) {
        var caption = original
        caption.position = nextCaptionPosition
        nextCaptionPosition += 1
        indices[caption.id] = captions.count
        captions.append(caption)
    }

    private func queueTranslation(_ id: UUID) {
        guard let service = apis?.translation else { return }
        translationQueue.append(TranslationJob(id: id, service: service))
        startQueuedTranslations()
    }

    private func publishOriginal() {
        let text = drafts.snapshot().paragraph(after: sentenceBatch.text, pending: pendingOriginals)
        let language = batchContext?.source ?? pendingOriginals.first?.originalLanguage ?? active?.configuredSource ?? source
        originalPreviews = SentenceBatcher.previewParagraphs(text, count: sentenceCount, language: language)
        let positions = nextCaptionPosition..<(nextCaptionPosition + originalPreviews.count)
        draftRows = draftRows.filter { positions.contains($0.key) }
        for position in positions where draftRows[position] == nil { draftRows[position] = DraftRow() }
        if let work = draftWork, work.captionID == nil, !positions.contains(work.position) {
            cancelDraftTranslation()
        }
        publishLiveParagraphs()
        startDraftTranslation()
    }

    private var previewTarget: Language {
        if !sentenceBatch.text.isEmpty, let batchContext { return batchContext.target }
        return pendingOriginals.first?.translationLanguage ?? target
    }

    private func publishLiveParagraphs() {
        let target = previewTarget
        let paragraphs = originalPreviews.enumerated().map { offset, preview in
            let position = nextCaptionPosition + offset
            let draft = draftRows[position]?.translation
            let translated = draft?.coversStart(of: preview.text, target: target) == true ? draft?.displayedText ?? "" : ""
            return LiveCaption(id: position, original: preview.text, translation: translated)
        }
        if paragraphs != liveParagraphs { liveParagraphs = paragraphs }
    }

    private func startDraftTranslation() {
        guard phase == .listening, draftWork == nil, translationQueue.isEmpty, workers.count < 4,
              let service = apis?.translation else { return }
        let target = previewTarget
        let now = ContinuousClock.now
        // Finish a full paragraph before refreshing a long, unfinished one.
        let candidate = originalPreviews.indices.first { index in
            let preview = originalPreviews[index]
            let draft = draftRows[nextCaptionPosition + index]?.translation
            return preview.fullBatch && draft?.matches(preview.text, target: target) != true
        } ?? originalPreviews.indices.last.flatMap { index -> Int? in
            let preview = originalPreviews[index]
            guard !preview.fullBatch, preview.text.count >= 32, let row = draftRows[nextCaptionPosition + index] else { return nil }
            var readyAt = row.firstSeenAt.advanced(by: .milliseconds(2500))
            if let draft = row.translation, draft.target == target {
                guard preview.text.count >= draft.original.count + 24 else { return nil }
                readyAt = max(readyAt, draft.startedAt.advanced(by: .seconds(2)))
            }
            if now < readyAt {
                scheduleDraftCheck(at: readyAt)
                return nil
            }
            return index
        }
        guard let index = candidate else { return }
        cancelDraftCheck()
        let original = originalPreviews[index].text
        let work = DraftWork(position: nextCaptionPosition + index)
        let old = draftRows[work.position]?.translation
        let fallback = old?.coversStart(of: original, target: target) == true ? old?.displayedText ?? "" : ""
        draftRows[work.position]?.translation = DraftTranslation(original: original, target: target, startedAt: now, fallback: fallback)
        let previous = index > 0 ? originalPreviews[index - 1].text : captions.last { !$0.original.isEmpty }?.original
        draftWork = work
        AppLog.event("translation.preview.requested")
        draftTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let text = try await TranslationAPI.shared.translate(original, to: target, service: service, previous: previous,
                                                                      draft: true) { [weak self] delta in
                    self?.receiveDraftDelta(delta, id: work.id)
                }
                self?.finishDraftTranslation(id: work.id, text: text)
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.failure("translation.preview.failed", error)
                self?.finishDraftTranslation(id: work.id, text: nil)
            }
        }
    }

    private func receiveDraftDelta(_ text: String, id: UUID) {
        guard let work = draftWork, work.id == id else { return }
        if work.captionID != nil {
            draftWork?.promotedText += text
        } else {
            draftRows[work.position]?.translation?.text += text
        }
        scheduleTranslationRefresh()
    }

    private func finishDraftTranslation(id: UUID, text: String?) {
        guard let work = draftWork, work.id == id else { return }
        draftWork = nil
        draftTask = nil
        if let captionID = work.captionID, let index = indices[captionID] {
            if let text {
                captions[index].translation = text
                captions[index].translationFinal = true
                captions[index].translationIsDraft = false
            } else {
                queueTranslation(captionID)
            }
        } else if let text {
            draftRows[work.position]?.translation?.text = text
            draftRows[work.position]?.translation?.completed = true
        }
        publishLiveParagraphs()
        startDraftTranslation()
    }

    private func cancelDraftTranslation() {
        draftTask?.cancel()
        draftTask = nil
        draftWork = nil
    }

    private func scheduleDraftCheck(at instant: ContinuousClock.Instant) {
        guard draftCheck == nil else { return }
        draftCheck = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: instant) }
            catch { return }
            self?.draftCheck = nil
            self?.startDraftTranslation()
        }
    }

    private func cancelDraftCheck() {
        draftCheck?.cancel()
        draftCheck = nil
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
        publishLiveParagraphs()
        if let work = draftWork, let id = work.captionID, let index = indices[id], !work.promotedText.isEmpty,
           captions[index].translation != work.promotedText {
            captions[index].translation = work.promotedText
        }
        guard !translationDeltas.isEmpty else { return }
        var updated = captions
        for (id, delta) in translationDeltas {
            guard let index = indices[id] else { continue }
            if updated[index].translationIsDraft {
                updated[index].translation = ""
                updated[index].translationIsDraft = false
            }
            updated[index].translation += delta
        }
        translationDeltas.removeAll(keepingCapacity: true)
        captions = updated
    }

    private func startQueuedTranslations() {
        while workers.count < 4, !translationQueue.isEmpty {
            let job = translationQueue.removeFirst()
            let id = job.id
            guard let index = indices[id] else { continue }
            let original = captions[index].original
            let previous = captions[..<index].last { $0.originalFinal && !$0.original.isEmpty }?.original
            let language = captions[index].translationLanguage
            if captions[index].translationFailed {
                if !captions[index].translationIsDraft { captions[index].translation = "" }
                captions[index].translationFailed = false
            }
            workers[id] = Task {
                defer {
                    if !Task.isCancelled {
                        workers.removeValue(forKey: id)
                        startQueuedTranslations()
                        startDraftTranslation()
                    }
                }
                do {
                    AppLog.latency("translation.queue_ms", since: job.enqueuedAt)
                    let text = try await TranslationAPI.shared.translate(original, to: language, service: job.service, previous: previous) { delta in
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
                        captions[index].translationIsDraft = false
                        storedPositions.remove(captions[index].position)
                    }
                } catch {
                    translationDeltas.removeValue(forKey: id)
                    if !Task.isCancelled, let index = indices[id] {
                        AppLog.failure("translation.failed", error)
                        if !captions[index].translationIsDraft { captions[index].translation = "" }
                        captions[index].translationFailed = true
                        storedPositions.remove(captions[index].position)
                        notice = description(for: error)
                    }
                }
            }
        }
    }

    private func cancelTranslations() {
        batchTimer?.cancel()
        batchTimer = nil
        cancelDraftTranslation()
        cancelDraftCheck()
        draftRows.removeAll()
        originalPreviews.removeAll()
        for worker in workers.values { worker.cancel() }
        workers.removeAll()
        translationQueue.removeAll()
        translationDeltas.removeAll()
        translationRefresh?.cancel()
        translationRefresh = nil
    }

    private func startArchiveTimer() {
        archiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard let self else { return }
                self.updateVisibleRange()
                await self.persistCaptions(evictOld: true)
            }
        }
    }

    private func updateVisibleRange() {
        let cutoff = max(0, recordingClock.elapsed().components.seconds - TranscriptArchive.visibleSeconds)
        if cutoff != visibleSince { visibleSince = cutoff }
    }

    private func persistCaptions(evictOld: Bool) async {
        guard let archive = transcriptArchive else { return }
        let writeNotice = "暂时无法写入字幕归档。原文和译文仍保留，App 会重试。"
        let cutoff = visibleSince
        let entries: [TranscriptArchive.Entry] = captions.compactMap { caption in
            guard !storedPositions.contains(caption.position), caption.translationFinal || caption.translationFailed,
                  let body = TextExport.block(caption) else { return nil }
            return .init(id: caption.position, text: body)
        }
        do {
            if !entries.isEmpty {
                try await Task.detached(priority: .utility) { try archive.write(entries) }.value
                hasArchivedCaptions = true
                let written = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.text) })
                for caption in captions where caption.translationFinal || caption.translationFailed {
                    if let body = written[caption.position], body == TextExport.block(caption) {
                        storedPositions.insert(caption.position)
                    }
                }
                if notice == writeNotice { notice = nil }
            }
        } catch {
            AppLog.failure("transcript.archive.write_failed", error)
            notice = writeNotice
            return
        }
        guard evictOld, cutoff > 0 else { return }
        let context = captions.last {
            ($0.recordingStartSeconds ?? .max) < cutoff && $0.originalFinal &&
                !$0.original.isEmpty
        }?.id
        let old = captions.filter { caption in
            guard caption.id != context, let seconds = caption.recordingStartSeconds, seconds < cutoff else { return false }
            return caption.original.isEmpty ||
                (caption.translationFinal && storedPositions.contains(caption.position))
        }
        guard !old.isEmpty else { return }
        let removed = Set(old.map(\.id))
        captions.removeAll { removed.contains($0.id) }
        indices = Dictionary(uniqueKeysWithValues: captions.enumerated().map { ($1.id, $0) })
        storedPositions.subtract(old.map(\.position))
    }

    private func recentEntries() -> [TranscriptArchive.Entry] {
        captions.compactMap { caption in
            TextExport.block(caption).map { .init(id: caption.position, text: $0) }
        }
    }

    func completeTranscript() -> Task<String, Error> {
        let recent = recentEntries()
        let archive = hasArchivedCaptions ? transcriptArchive : nil
        let markers = markers
        return Task.detached(priority: .utility) {
            try TranscriptArchive.render(archived: archive?.read() ?? [], recent: recent, markers: markers)
        }
    }

    func historyPage(before: Int) async throws -> [TranscriptArchive.Entry] {
        let limit = TranscriptArchive.pageSize + 1
        let recent = captions.reversed().lazy.filter { $0.position < before }.compactMap { caption in
            TextExport.block(caption).map { TranscriptArchive.Entry(id: caption.position, text: $0) }
        }.prefix(limit)
        let snapshot = Array(recent)
        let archive = hasArchivedCaptions ? transcriptArchive : nil
        return try await Task.detached(priority: .utility) {
            let stored = try archive?.read(before: before, limit: limit) ?? []
            var entries = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            for entry in snapshot { entries[entry.id] = entry }
            return Array(entries.values.sorted { $0.id > $1.id }.prefix(limit))
        }.value
    }

    func discardSavedArchive() {
        if archiveSaved { transcriptArchive?.discard() }
    }

    func markTranscriptExported(historyID: UUID) {
        if self.historyID == historyID { archiveSaved = true }
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
        if let failure = error as? APISettingError { return failure.localizedDescription }
        return "API 请求失败 · \(error.localizedDescription)"
    }
}
