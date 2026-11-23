import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import os

enum AudioEvent {
    case audio(Data)
    case commit(SpeechBoundary)
}

struct SpeechBoundary {
    let voicedFrames: Int
    let silentFrames: Int

    // Eight 20 ms frames are enough evidence to flag a possibly missed short word.
    var hasSustainedSignal: Bool { voicedFrames >= 8 }
}

struct SoundActivity {
    private(set) var lastHeardAt: SuspendingClock.Instant?
    private var audibleFrames = 0

    mutating func ingest(audible: Bool, at now: @autoclosure () -> SuspendingClock.Instant = SuspendingClock().now) {
        guard audible else {
            audibleFrames = 0
            return
        }
        // Require 80 ms of activity so an isolated click does not reset the timer.
        if audibleFrames < 4 { audibleFrames += 1 }
        if audibleFrames == 4 { lastHeardAt = now() }
    }
}

struct QueuedAudioEvent {
    let event: AudioEvent
    let queuedAt: ContinuousClock.Instant
    var recordingSeconds: Int64? = nil
}

struct AudioPacketBatcher {
    static let packetBytes = 4 * SpeechSegmenter.bytesPerFrame
    private var isFirstPacket = true
    private var buffered = Data()
    private var bufferedAt: ContinuousClock.Instant?

    mutating func append(_ event: AudioEvent, now: ContinuousClock.Instant,
                         recordingSeconds: Int64? = nil) -> [QueuedAudioEvent] {
        switch event {
        case .audio(let data):
            if isFirstPacket {
                isFirstPacket = false
                return [QueuedAudioEvent(event: .audio(data), queuedAt: now, recordingSeconds: recordingSeconds)]
            }
            if buffered.isEmpty { bufferedAt = now }
            buffered.append(data)
            return buffered.count >= Self.packetBytes ? flush() : []
        case .commit:
            isFirstPacket = true
            return flush() + [QueuedAudioEvent(event: event, queuedAt: now, recordingSeconds: recordingSeconds)]
        }
    }

    private mutating func flush() -> [QueuedAudioEvent] {
        guard let bufferedAt else { return [] }
        let packet = QueuedAudioEvent(event: .audio(buffered), queuedAt: bufferedAt)
        buffered = Data()
        self.bufferedAt = nil
        return [packet]
    }
}

struct SpeechSegmenter {
    enum Sensitivity {
        case microphone, system

        var initialNoiseFloor: Double { self == .microphone ? 35 : 100 }

        func threshold(noiseFloor: Double, isSpeaking: Bool) -> Double {
            switch self {
            case .system: max(180, noiseFloor * 2.8)
            case .microphone:
                isSpeaking ? max(45, noiseFloor * 1.55) : max(65, noiseFloor * 1.9)
            }
        }
    }

    static let sampleRate = 24_000
    static let samplesPerFrame = 480
    static let bytesPerFrame = samplesPerFrame * 2
    private var preRoll: [Data] = []
    private let sensitivity: Sensitivity
    private let limits: SegmentationLength.Limits
    private var noiseFloor: Double
    private var voicedFrames = 0
    private var turnVoicedFrames = 0
    private var activeFrames = 0
    private var silentFrames = 0
    private var continuing = false
    private(set) var processedFrames: Int64 = 0
    private(set) var speechStartSample: Int64 = 0
    private(set) var lastRMS = 0.0
    private(set) var lastThreshold = 0.0

    init(sensitivity: Sensitivity = .system, length: SegmentationLength = .standard) {
        self.sensitivity = sensitivity
        limits = length.limits
        noiseFloor = sensitivity.initialNoiseFloor
    }

    mutating func ingest(_ frame: Data) -> [AudioEvent] {
        processedFrames += 1
        let level = frame.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            let squared = samples.reduce(0.0) { sum, sample in
                let amplitude = Double(sample)
                return sum + amplitude * amplitude
            }
            return sqrt(squared / Double(samples.count))
        }
        let threshold = sensitivity.threshold(noiseFloor: noiseFloor, isSpeaking: activeFrames > 0)
        lastRMS = level
        lastThreshold = threshold
        let voiced = level > threshold
        if activeFrames == 0 {
            preRoll.append(frame)
            if preRoll.count > 11 { preRoll.removeFirst() }
            if voiced {
                voicedFrames += 1
            } else {
                voicedFrames = 0
                noiseFloor = noiseFloor * 0.98 + level * 0.02
            }
            guard voicedFrames >= (continuing ? 1 : 2) else { return [] }
            speechStartSample = (processedFrames - Int64(voicedFrames)) * Int64(Self.samplesPerFrame)
            activeFrames = preRoll.count
            turnVoicedFrames = voicedFrames
            silentFrames = 0
            var audio = Data()
            for buffered in preRoll { audio.append(buffered) }
            preRoll.removeAll(keepingCapacity: true)
            return [.audio(audio)]
        }

        activeFrames += 1
        if voiced { turnVoicedFrames += 1 }
        silentFrames = voiced ? 0 : silentFrames + 1
        let pauseFrames = activeFrames >= limits.longTurnFrames ? limits.longTurnPauseFrames : limits.pauseFrames
        let endedAtPause = silentFrames >= pauseFrames
        if endedAtPause || activeFrames >= limits.maximumFrames {
            continuing = !endedAtPause
            let boundary = speechBoundary
            resetActive()
            return [.audio(frame), .commit(boundary)]
        }
        return [.audio(frame)]
    }

    mutating func finish() -> [AudioEvent] {
        defer {
            resetActive()
            preRoll.removeAll()
            continuing = false
        }
        guard activeFrames > 0 else { return [] }
        // Realtime requires at least 100 ms for a manual commit.
        if activeFrames < 5 {
            let padding = Data(count: (5 - activeFrames) * Self.bytesPerFrame)
            return [.audio(padding), .commit(speechBoundary)]
        }
        return [.commit(speechBoundary)]
    }

    private var speechBoundary: SpeechBoundary {
        SpeechBoundary(voicedFrames: turnVoicedFrames, silentFrames: silentFrames)
    }

    private mutating func resetActive() {
        activeFrames = 0
        silentFrames = 0
        voicedFrames = 0
        turnVoicedFrames = 0
    }
}

enum RecoveryAudio {
    static func amplifyQuietPCM(_ pcm: Data) -> Data {
        guard pcm.count.isMultiple(of: 2) else { return pcm }
        let peak = pcm.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        }
        guard peak > 0 else { return pcm }
        // Raise quiet recordings by at most 12 dB with headroom for peaks.
        let gain = min(4.0, 16_000.0 / Double(peak))
        guard gain > 1 else { return pcm }
        var amplified = pcm
        amplified.withUnsafeMutableBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for index in samples.indices {
                samples[index] = Int16((Double(samples[index]) * gain).rounded())
            }
        }
        return amplified
    }
}

struct AudioInput: Identifiable {
    static let defaultID = "default"
    static let systemID = "system"

    let id: String
    let name: String
    let device: AudioDeviceID

    static func devices() -> [AudioInput] {
        var property = hardwareDevicesProperty
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !devices.isEmpty else { return [] }
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride).compactMap { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: device),
                  let name = stringProperty(kAudioObjectPropertyName, of: device) else { return nil }
            return AudioInput(id: uid, name: name, device: device)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var hardwareDevicesProperty: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var string: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: string))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &string) == noErr else { return nil }
        return string?.takeRetainedValue() as String?
    }
}

typealias AudioEvents = AsyncThrowingStream<QueuedAudioEvent, Error>

@MainActor
final class AudioCapture {
    private let inputID: String
    private let processor: AudioProcessor
    private(set) var engine: AVAudioEngine?
    private var systemAudioStop: (() async -> Void)?
    private var systemAudioShutdown: Task<Void, Never>?
    private var stopped = false
    var lastHeardAt: SuspendingClock.Instant? { processor.lastHeardAt }

    init(inputID: String, length: SegmentationLength, recording: SessionRecording) {
        self.inputID = inputID
        processor = AudioProcessor(sensitivity: inputID == AudioInput.systemID ? .system : .microphone,
                                   length: length, recording: recording)
    }

    func start() async throws -> AudioEvents {
        if inputID == AudioInput.systemID {
            AppLog.event("audio.system.permission_check")
            try await startSystemAudio()
        } else {
            AppLog.event(inputID == AudioInput.defaultID ? "audio.microphone.default" : "audio.microphone.selected")
            AppLog.event("audio.microphone.permission_check")
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppFailure.microphoneDenied }
            guard !stopped else { throw CancellationError() }
            AppLog.event("audio.microphone.authorized")
            try startMicrophone()
        }
        guard !stopped else { throw CancellationError() }
        AppLog.event("audio.started")
        return processor.events
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let systemAudioStop {
            self.systemAudioStop = nil
            systemAudioShutdown = Task {
                await systemAudioStop()
                processor.finish()
            }
            return
        }
        processor.finish()
    }

    func stopAndDrain() async {
        stop()
        await systemAudioShutdown?.value
        await withCheckedContinuation { continuation in
            processor.queue.async { continuation.resume() }
        }
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if inputID != AudioInput.defaultID {
            guard var device = AudioInput.devices().first(where: { $0.id == inputID })?.device else {
                throw AppFailure.inputUnavailable
            }
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw AppFailure.inputUnavailable
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AppFailure.microphone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [processor] input, _ in
            processor.copyFromTap(input)
        }
        self.engine = engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw AppFailure.microphone
        }
    }

    private func startSystemAudio() async throws {
        guard #available(macOS 14.2, *) else { throw AppFailure.systemAudioRequiresUpdate }
        let tap = SystemAudioTap(processor: processor)
        try await tap.start()
        guard !stopped else {
            await tap.stopAndWait()
            throw CancellationError()
        }
        systemAudioStop = { await tap.stopAndWait() }
    }
}

final class AudioProcessor: @unchecked Sendable {
    let queue = DispatchQueue(label: "classroom-captions.audio", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 24)
    // Keep roughly the former queue duration with 80 ms packets.
    private let stream = AudioEvents.makeStream(bufferingPolicy: .bufferingOldest(210))
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SpeechSegmenter.sampleRate),
                                       channels: 1, interleaved: true)!
    private let recording: SessionRecording?
    private var converter: AVAudioConverter?
    private var segmenter: SpeechSegmenter
    private var packetBatcher = AudioPacketBatcher()
    private var remainder = Data()
    private var recordingStartSample: Int64?
    private var finished = false
    private var signalFrames = 0
    private var signalPeak = 0.0
    private var framesAboveGate = 0
    private let activity = OSAllocatedUnfairLock(initialState: SoundActivity())

    init(sensitivity: SpeechSegmenter.Sensitivity = .system, length: SegmentationLength = .standard,
         recording: SessionRecording? = nil) {
        segmenter = SpeechSegmenter(sensitivity: sensitivity, length: length)
        self.recording = recording
    }

    var events: AudioEvents { stream.stream }
    var lastHeardAt: SuspendingClock.Instant? { activity.withLock { $0.lastHeardAt } }

    func copyFromTap(_ input: AVAudioPCMBuffer) {
        guard slots.wait(timeout: .now()) == .success else {
            AppLog.event("audio.capture.overload")
            stream.continuation.finish(throwing: AppFailure.audioOverload)
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            slots.signal()
            stream.continuation.finish(throwing: AppFailure.microphone)
            return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            if let from = source[index].mData, let to = target[index].mData {
                memcpy(to, from, Int(source[index].mDataByteSize))
            }
        }
        queue.async {
            defer { self.slots.signal() }
            self.convert(copy)
        }
    }

    func ingestSystemAudio(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard input.pointee.mNumberBuffers == 1,
              input.pointee.mBuffers.mDataByteSize > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
        copyFromTap(buffer)
    }

    func systemAudioInterrupted() {
        queue.async { self.end(throwing: AppFailure.systemAudioInterrupted) }
    }

    func finish() {
        queue.async { self.end() }
    }

    private func end(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        emit(segmenter.finish())
        stream.continuation.finish(throwing: error)
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard !finished else { return }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: output)
        }
        let frames = ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate)
        guard let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames) + 64) else {
            end(throwing: AppFailure.audioFormat)
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, result in
            result.pointee = supplied ? .noDataNow : .haveData
            if supplied { return nil }
            supplied = true
            return input
        }
        if status == .error {
            end(throwing: AppFailure.audioFormat)
            return
        }
        guard let samples = buffer.int16ChannelData?.pointee, buffer.frameLength > 0 else { return }
        if let offset = recording?.append(buffer), recordingStartSample == nil {
            recordingStartSample = offset
        }
        remainder.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        while remainder.count >= SpeechSegmenter.bytesPerFrame {
            let frame = Data(remainder.prefix(SpeechSegmenter.bytesPerFrame))
            remainder.removeFirst(SpeechSegmenter.bytesPerFrame)
            let events = segmenter.ingest(frame)
            summarizeSignal()
            emit(events)
        }
    }

    private func summarizeSignal() {
        signalFrames += 1
        signalPeak = max(signalPeak, segmenter.lastRMS)
        let audible = segmenter.lastRMS > segmenter.lastThreshold
        activity.withLock { $0.ingest(audible: audible) }
        if audible { framesAboveGate += 1 }
        guard signalFrames == 500 else { return }
        AppLog.audioSignal(peak: signalPeak, threshold: segmenter.lastThreshold, voicedFrames: framesAboveGate)
        signalFrames = 0
        signalPeak = 0
        framesAboveGate = 0
    }

    private func emit(_ events: [AudioEvent]) {
        guard !events.isEmpty else { return }
        let now = ContinuousClock.now
        let startSeconds = recordingStartSample.map { ($0 + segmenter.speechStartSample) / Int64(SpeechSegmenter.sampleRate) }
        let endSeconds = recordingStartSample.map {
            ($0 + segmenter.processedFrames * Int64(SpeechSegmenter.samplesPerFrame)) / Int64(SpeechSegmenter.sampleRate)
        }
        for event in events {
            let timestamp: Int64?
            switch event {
            case .audio: timestamp = startSeconds
            case .commit: timestamp = endSeconds
            }
            for packet in packetBatcher.append(event, now: now, recordingSeconds: timestamp) {
                if case .dropped = stream.continuation.yield(packet) {
                    AppLog.event("audio.upload.overload")
                    stream.continuation.finish(throwing: AppFailure.audioOverload)
                    return
                }
            }
        }
    }
}
