import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Observes output level and mute state on the active system output device.
/// Device changes only move the listener; they do not surface an activity.
@MainActor
final class VolumeActivitySource: ObservableObject {
    struct Snapshot: Equatable {
        let level: Int
        let isMuted: Bool
    }

    let events = PassthroughSubject<Snapshot, Never>()

    private var outputDevice = kAudioObjectUnknown
    private var volumeAddress: AudioObjectPropertyAddress?
    private var previousSnapshot: Snapshot?

    /// Wall-clock time of the last user-initiated volume change
    /// (MediaKeySuppressor calling `adjust(by:)` or `toggleMute()` from
    /// a key press). Stream changes outside this window — apps ducking
    /// for audio, Touch Bar slider, Control Center, AppleScript — are
    /// applied to `previousSnapshot` silently. Mirrors the brightness
    /// gating so neither HUD flickers under programmatic nudges.
    private var lastUserAdjustAt: Date?
    private let userIntentWindow: TimeInterval = 1.5

    nonisolated private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    nonisolated private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    nonisolated private static let virtualMainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    nonisolated private static let scalarVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard outputDevice == kAudioObjectUnknown else { return }
        var address = Self.defaultOutputAddress
        guard AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.systemOutputChanged,
            Unmanaged.passUnretained(self).toOpaque()
        ) == noErr else {
            return
        }
        rebindOutputDevice()
    }

    func stop() {
        detachOutputListeners()
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.systemOutputChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        outputDevice = kAudioObjectUnknown
        previousSnapshot = nil
    }

    deinit {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if outputDevice != kAudioObjectUnknown {
            if var volumeAddress {
                AudioObjectRemovePropertyListener(outputDevice, &volumeAddress, Self.deviceLevelChanged, context)
            }
            var muteAddress = Self.muteAddress
            AudioObjectRemovePropertyListener(outputDevice, &muteAddress, Self.deviceLevelChanged, context)
        }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.systemOutputChanged,
            context
        )
    }

    private func rebindOutputDevice() {
        detachOutputListeners()

        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultOutputAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != kAudioObjectUnknown else {
            return
        }

        outputDevice = device
        if Self.hasProperty(Self.virtualMainVolumeAddress, on: device) {
            volumeAddress = Self.virtualMainVolumeAddress
        } else if Self.hasProperty(Self.scalarVolumeAddress, on: device) {
            volumeAddress = Self.scalarVolumeAddress
        }

        if var volumeAddress {
            AudioObjectAddPropertyListener(
                device,
                &volumeAddress,
                Self.deviceLevelChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        if Self.hasProperty(Self.muteAddress, on: device) {
            var muteAddress = Self.muteAddress
            AudioObjectAddPropertyListener(
                device,
                &muteAddress,
                Self.deviceLevelChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        refresh(emit: false)
    }

    private func detachOutputListeners() {
        guard outputDevice != kAudioObjectUnknown else { return }
        if var volumeAddress {
            AudioObjectRemovePropertyListener(
                outputDevice,
                &volumeAddress,
                Self.deviceLevelChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        if Self.hasProperty(Self.muteAddress, on: outputDevice) {
            var muteAddress = Self.muteAddress
            AudioObjectRemovePropertyListener(
                outputDevice,
                &muteAddress,
                Self.deviceLevelChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        outputDevice = kAudioObjectUnknown
        volumeAddress = nil
    }

    /// Apply a delta to the system output volume, clamped to [0, 1].
    /// Mirrors the system default: if muted and we're stepping by a
    /// nonzero amount, unmute first so the user hears the change.
    func adjust(by delta: Float) {
        guard outputDevice != kAudioObjectUnknown, var volumeAddress else { return }
        var current: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(outputDevice, &volumeAddress, 0, nil, &size, &current) == noErr,
              current.isFinite else { return }
        let next = min(max(current + delta, 0), 1)
        lastUserAdjustAt = Date()

        var changedSomething = false
        if next != current {
            var applied = next
            AudioObjectSetPropertyData(outputDevice, &volumeAddress, 0, nil, size, &applied)
            changedSomething = true
        }

        var isMuted = false
        if Self.hasProperty(Self.muteAddress, on: outputDevice) {
            var muteAddress = Self.muteAddress
            var muted: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(outputDevice, &muteAddress, 0, nil, &muteSize, &muted) == noErr {
                isMuted = muted != 0
                if delta != 0, muted != 0 {
                    var unmute: UInt32 = 0
                    AudioObjectSetPropertyData(outputDevice, &muteAddress, 0, nil, muteSize, &unmute)
                    isMuted = false
                    changedSomething = true
                }
            }
        }

        if !changedSomething {
            // Pinned at the boundary (0% / 100%) with nothing toggled: the
            // CoreAudio listener won't fire, and `refresh` would dedup
            // against `previousSnapshot` anyway. Emit directly so repeated
            // key presses at the limit keep flashing the current level.
            events.send(Snapshot(
                level: min(max(Int((current * 100).rounded()), 0), 100),
                isMuted: isMuted
            ))
        }
    }

    /// Flip the mute state on the current output device.
    func toggleMute() {
        guard outputDevice != kAudioObjectUnknown,
              Self.hasProperty(Self.muteAddress, on: outputDevice) else { return }
        var muteAddress = Self.muteAddress
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(outputDevice, &muteAddress, 0, nil, &size, &muted) == noErr else { return }
        var next: UInt32 = muted == 0 ? 1 : 0
        lastUserAdjustAt = Date()
        AudioObjectSetPropertyData(outputDevice, &muteAddress, 0, nil, size, &next)
    }

    private func refresh(emit: Bool) {
        guard outputDevice != kAudioObjectUnknown, var volumeAddress else { return }

        var scalar: Float32 = 0
        var scalarSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            outputDevice,
            &volumeAddress,
            0,
            nil,
            &scalarSize,
            &scalar
        ) == noErr, scalar.isFinite else {
            return
        }

        var muteAddress = Self.muteAddress
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if Self.hasProperty(Self.muteAddress, on: outputDevice) {
            _ = AudioObjectGetPropertyData(outputDevice, &muteAddress, 0, nil, &muteSize, &muted)
        }

        let snapshot = Snapshot(
            level: min(max(Int((scalar * 100).rounded()), 0), 100),
            isMuted: muted != 0
        )
        guard snapshot != previousSnapshot else { return }
        previousSnapshot = snapshot
        guard emit else { return }
        // Same user-intent gate as brightness — suppress the activity
        // for programmatic / slider / app-driven volume changes.
        let recent = lastUserAdjustAt.map { Date().timeIntervalSince($0) < userIntentWindow } ?? false
        guard recent else { return }
        events.send(snapshot)
    }

    private static func hasProperty(_ address: AudioObjectPropertyAddress, on device: AudioObjectID) -> Bool {
        var address = address
        return AudioObjectHasProperty(device, &address)
    }

    nonisolated(unsafe) private static let systemOutputChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let source = Unmanaged<VolumeActivitySource>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            source.rebindOutputDevice()
        }
        return noErr
    }

    nonisolated(unsafe) private static let deviceLevelChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let source = Unmanaged<VolumeActivitySource>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            source.refresh(emit: true)
        }
        return noErr
    }
}
