import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

enum AudioEvent {
    case audio(Data)
    case commit
}

struct SpeechSegmenter {
    static let samplesPerFrame = 480
    static let bytesPerFrame = samplesPerFrame * 2
    // At 20 ms per frame, look for a shorter pause as a turn gets longer.
    static let sentencePauseFrames = 42
    static let longTurnPauseFrames = 22
    static let longTurnFrames = 400
    static let maximumTurnFrames = 600

    private var preRoll: [Data] = []
    private var noiseFloor = 100.0
    private var voicedFrames = 0
    private var activeFrames = 0
    private var silentFrames = 0
    private var continuing = false

    mutating func ingest(_ frame: Data) -> [AudioEvent] {
        let level = frame.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            let squared = samples.reduce(0.0) { sum, sample in
                let amplitude = Double(sample)
                return sum + amplitude * amplitude
            }
            return sqrt(squared / Double(samples.count))
        }
        let voiced = level > max(180, noiseFloor * 2.8)
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
            activeFrames = preRoll.count
            silentFrames = 0
            var audio = Data()
            for buffered in preRoll { audio.append(buffered) }
            preRoll.removeAll(keepingCapacity: true)
            return [.audio(audio)]
        }

        activeFrames += 1
        silentFrames = voiced ? 0 : silentFrames + 1
        let pauseFrames = activeFrames >= Self.longTurnFrames ? Self.longTurnPauseFrames : Self.sentencePauseFrames
        let endedAtPause = silentFrames >= pauseFrames
        if endedAtPause || activeFrames >= Self.maximumTurnFrames {
            continuing = !endedAtPause
            resetActive()
            return [.audio(frame), .commit]
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
            return [.audio(padding), .commit]
        }
        return [.commit]
    }

    private mutating func resetActive() {
        activeFrames = 0
        silentFrames = 0
        voicedFrames = 0
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

typealias AudioEvents = AsyncThrowingStream<AudioEvent, Error>

@MainActor
final class AudioCapture {
    private let inputID: String
    private let processor = AudioProcessor()
    private(set) var engine: AVAudioEngine?
    private var screenStream: SCStream?
    private var screenStarting = false
    private var stopped = false

    init(inputID: String) {
        self.inputID = inputID
    }

    func start() async throws -> AudioEvents {
        if inputID == AudioInput.systemID {
            try await startSystemAudio()
        } else {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppFailure.microphoneDenied }
            guard !stopped else { throw CancellationError() }
            try startMicrophone()
        }
        guard !stopped else { throw CancellationError() }
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
        if !screenStarting { stopSystemAudio() }
        processor.finish()
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
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !stopped else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw AppFailure.systemAudio
            }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
            configuration.width = 32
            configuration.height = 32
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: configuration, delegate: processor)
            try stream.addStreamOutput(processor, type: .audio, sampleHandlerQueue: processor.queue)
            screenStream = stream
            screenStarting = true
            defer {
                screenStarting = false
                if stopped { stopSystemAudio() }
            }
            try await stream.startCapture()
        } catch {
            if stopped || error is CancellationError { throw CancellationError() }
            stopSystemAudio()
            if !CGPreflightScreenCaptureAccess() { throw AppFailure.systemAudioDenied }
            throw AppFailure.systemAudio
        }
    }

    private func stopSystemAudio() {
        guard let screenStream else { return }
        self.screenStream = nil
        let processor = processor
        Task {
            try? screenStream.removeStreamOutput(processor, type: .audio)
            try? await screenStream.stopCapture()
        }
    }
}

final class AudioProcessor: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "classroom-captions.audio", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 24)
    private let stream = AudioEvents.makeStream(bufferingPolicy: .bufferingOldest(850))
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var segmenter = SpeechSegmenter()
    private var remainder = Data()
    private var finished = false

    var events: AudioEvents { stream.stream }

    func copyFromTap(_ input: AVAudioPCMBuffer) {
        guard slots.wait(timeout: .now()) == .success else {
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { ingestSystemSample(sample) }
    }

    func ingestSystemSample(_ sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, sample.isValid, sample.numSamples > 0, let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            end(throwing: AppFailure.systemAudio)
            return
        }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else {
            end(throwing: AppFailure.systemAudio)
            return
        }
        convert(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
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
        remainder.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        while remainder.count >= SpeechSegmenter.bytesPerFrame {
            let frame = Data(remainder.prefix(SpeechSegmenter.bytesPerFrame))
            remainder.removeFirst(SpeechSegmenter.bytesPerFrame)
            emit(segmenter.ingest(frame))
        }
    }

    private func emit(_ events: [AudioEvent]) {
        for event in events {
            if case .dropped = stream.continuation.yield(event) {
                stream.continuation.finish(throwing: AppFailure.audioOverload)
                break
            }
        }
    }
}
