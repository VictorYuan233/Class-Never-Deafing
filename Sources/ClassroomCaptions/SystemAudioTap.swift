import AVFoundation
import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "classroom-captions.system-audio", qos: .userInitiated)
    private let processor: AudioProcessor
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var callback: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var started = false

    init(processor: AudioProcessor) {
        self.processor = processor
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.open()
                    continuation.resume()
                } catch {
                    self.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.close()
                continuation.resume()
            }
        }
    }

    private func open() throws {
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.property(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let ownProcess = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    UInt32(MemoryLayout<pid_t>.size), &pid, &bytes, &process)
        let excluded = ownProcess == noErr && process != kAudioObjectUnknown ? [process] : []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Class Never Deafing"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))

        var formatDescription = AudioStreamBasicDescription()
        bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = Self.property(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &bytes, &formatDescription))
        guard formatDescription.mChannelsPerFrame == 1, formatDescription.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &formatDescription) else { throw AppFailure.audioFormat }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Class Never Deafing",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device))
        try check(AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) { [processor] _, input, _, _, _ in
            processor.ingestSystemAudio(input, format: format)
        })
        guard let callback else { throw AppFailure.systemAudio }
        try check(AudioDeviceStart(device, callback))
        started = true
        var alive = Self.property(kAudioDevicePropertyDeviceIsAlive)
        let listener: AudioObjectPropertyListenerBlock = { [processor] _, _ in processor.systemAudioInterrupted() }
        if AudioObjectAddPropertyListenerBlock(device, &alive, queue, listener) == noErr { deviceListener = listener }
    }

    private func close() {
        if let deviceListener {
            var alive = Self.property(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(device, &alive, queue, deviceListener)
            self.deviceListener = nil
        }
        if let callback {
            if started { AudioDeviceStop(device, callback) }
            AudioDeviceDestroyIOProcID(device, callback)
            self.callback = nil
        }
        started = false
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        AppLog.event("audio.system.core_audio_error", number: Int(status))
        if status == kAudioDevicePermissionsError { throw AppFailure.systemAudioDenied }
        throw AppFailure.systemAudio
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
