import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class ClassroomSession: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, starting, listening, pausing, paused, reconnecting, stopping
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "准备就绪"
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var preview = ""
    @Published private(set) var notice: String?
    @Published private(set) var recordingClock = RecordingClock()
    @Published private(set) var automaticExportURL: URL?
    @Published private(set) var hasError = false
    var exportFolder: URL?

    private var previews: [UUID: [String: String]] = [:]
    private var indices: [UUID: Int] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var translationQueue: [UUID] = []
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
    private var key: String?
    private var inputChanged = false
    private var resumeSignal: CheckedContinuation<Void, Never>?

    var canExport: Bool {
        phase == .idle && captions.contains { $0.originalFinal && !$0.original.isEmpty }
    }

    func start(
        source: Language, target: Language, transcription: TranscriptionModel, translation: TranslationConfiguration,
        audioInputID: String, authorize: @escaping @MainActor () async throws -> String?
    ) {
        guard phase == .idle else { return }
        AppLog.event("session.start.requested")
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
                prepare(transcription: transcription, translation: translation, audioInputID: audioInputID, key: key)
                await run()
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
        translation: TranslationConfiguration, audioInputID: String, key: String
    ) {
        cancelTranslations()
        captions.removeAll()
        indices.removeAll()
        previews.removeAll()
        preview = ""
        notice = nil
        recordingClock = RecordingClock()
        automaticExportURL = nil
        self.audioInputID = audioInputID
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

    func pause() {
        guard phase == .listening else { return }
        AppLog.event("session.pause")
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
            cancelTranslations()
            for index in captions.indices where captions[index].originalFinal && !captions[index].translationFinal {
                captions[index].translationFailed = true
            }
            sessionTask?.cancel()
        }
    }

    func retryTranslation(_ id: UUID) {
        guard workers[id] == nil, !translationQueue.contains(id), let index = indices[id],
              captions[index].translationFailed else { return }
        Task {
            do {
                let credential: String?
                if let key { credential = key } else { credential = try await KeyStore.read() }
                guard workers[id] == nil, !translationQueue.contains(id), let index = indices[id],
                      captions[index].translationFailed else { return }
                guard let credential else {
                    notice = "请先在设置中保存 OpenAI API Key。"
                    return
                }
                translationQueue.append(id)
                startQueuedTranslations(using: credential)
            } catch {
                if indices[id] != nil { notice = error.localizedDescription }
            }
        }
    }

    private func run() async {
        defer { finishSession() }
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
                let input = AudioCapture(inputID: audioInputID)
                capture = input
                status = "正在启动音频输入…"
                let audio = try await input.start()
                guard phase != .stopping else { break }
                recordingClock.resume()
                phase = .listening
                AppLog.event("session.listening")
                listeningSince = Date()
                status = "正在监听"
                let delay: Duration = connection.configuredSource == source ? .seconds(55 * 60) : .zero
                scheduleRotation(key: key, delay: delay)
                try await upload(audio, tracking: input)
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
                capture?.stop()
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

        while connections.values.contains(where: \.outstanding) || !workers.isEmpty || !translationQueue.isEmpty {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishPause() {
        if let active { retire(active) }
        active = nil
        updatePreview()
        phase = .paused
        status = "已暂停"
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
        do {
            for try await event in audio {
                switch event {
                case .audio(let data):
                    if segment == nil {
                        await switchSourceAtBoundary()
                        let caption = Caption()
                        indices[caption.id] = captions.count
                        captions.append(caption)
                        segment = caption.id
                    }
                    guard let active else { return }
                    try await active.append(data)
                case .commit:
                    if let id = segment, let active {
                        if let index = indices[id] { captions[index].translationLanguage = target }
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
        previews.removeValue(forKey: connection.id)
        updatePreview()
        retirements.removeValue(forKey: connection.id)?.cancel()
    }

    private func closeAll() {
        cancelRotation()
        for connection in Array(connections.values) { remove(connection) }
        active = nil
    }

    private func finishSession() {
        let stoppedByUser = phase == .stopping
        recordingClock.pause()
        closeAll()
        capture?.stop()
        capture = nil
        stopDeadline?.cancel()
        stopDeadline = nil
        key = nil
        sessionTask = nil
        phase = .idle
        AppLog.event("session.ended", number: Int(recordingClock.elapsed().components.seconds))
        guard stoppedByUser else { return }
        let text = TextExport.render(captions)
        guard !text.isEmpty else {
            status = "已停止 · 没有可保存的字幕"
            return
        }
        do {
            automaticExportURL = try TextExport.saveAutomatically(
                text, in: exportFolder ?? TextExport.automaticFolder, createFolder: exportFolder == nil
            )
            status = "已停止 · 字幕已保存"
            AppLog.event("export.success")
        } catch {
            AppLog.failure("export.failed", error)
            hasError = true
            status = "已停止 · 自动保存失败"
            notice = "请检查保存目录，或从菜单栏选择「另存本节课文本」。"
        }
    }

    private func apply(_ event: RealtimeEvent) {
        switch event {
        case .preview(let connection, let item, let delta):
            previews[connection, default: [:]][item, default: ""] += delta
            updatePreview()
        case .bound(let connection, let item, let segment):
            let text = previews[connection]?.removeValue(forKey: item)
            if let index = indices[segment], let text {
                captions[index].original = text
            }
            updatePreview()
        case .delta(let id, let text):
            if let index = indices[id] { captions[index].original += text }
        case .final(let id, let text):
            guard let index = indices[id], !captions[index].originalFinal else { return }
            let groups = TranslationSegments.split(text)
            captions[index].original = groups.first ?? ""
            captions[index].originalFinal = true
            let target = captions[index].translationLanguage
            let following = groups.dropFirst().map {
                Caption(original: $0, originalFinal: true, translationLanguage: target)
            }
            if !following.isEmpty {
                captions.insert(contentsOf: following, at: index + 1)
                for position in (index + 1)..<captions.count {
                    indices[captions[position].id] = position
                }
            }
            if !groups.isEmpty, let key {
                translationQueue.append(id)
                translationQueue.append(contentsOf: following.map(\.id))
                startQueuedTranslations(using: key)
            }
        case .failed(let id):
            if let index = indices[id], !captions[index].originalFinal {
                captions[index].originalFailed = true
            }
        }
    }

    private func updatePreview() {
        preview = active.flatMap { previews[$0.id]?.values.first } ?? ""
    }

    private func startQueuedTranslations(using credential: String) {
        while workers.count < 4, !translationQueue.isEmpty {
            let id = translationQueue.removeFirst()
            guard let index = indices[id] else { continue }
            let original = captions[index].original
            let previous = captions[..<index].last { $0.originalFinal && !$0.original.isEmpty }?.original
            let language = captions[index].translationLanguage
            let model = translationModel
            captions[index].translation = ""
            captions[index].translationFailed = false
            workers[id] = Task {
                defer {
                    if !Task.isCancelled {
                        workers.removeValue(forKey: id)
                        startQueuedTranslations(using: credential)
                    }
                }
                do {
                    let text = try await TranslationAPI.translate(original, to: language, model: model, previous: previous, key: credential) { delta in
                        if !Task.isCancelled, let index = self.indices[id] { self.captions[index].translation += delta }
                    }
                    try Task.checkCancellation()
                    if let index = indices[id] {
                        captions[index].translation = text
                        captions[index].translationFinal = true
                    }
                } catch {
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
