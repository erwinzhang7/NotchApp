import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Intercepts hardware brightness / volume / mute keys before macOS sees
/// them and drives the equivalent change ourselves. Result: the system
/// OSDUIHelper never fires, so the user only sees our notch activity
/// ribbon — no double HUD.
///
/// Requires Accessibility permission (System Settings → Privacy & Security
/// → Accessibility). Without it, `CGEvent.tapCreate` returns nil and
/// suppression is silently a no-op — the system continues to handle the
/// keys natively. We surface a one-time NSAlert pointing the user there
/// and then poll for trust every couple seconds so granting it mid-session
/// activates suppression without a relaunch.
///
/// Step sizes mirror the macOS default exactly:
/// - Plain key: 1/16 (0.0625)
/// - Shift + Option held: 1/64 (0.015625), the fine-grain quarter step
@MainActor
final class MediaKeySuppressor {
    private let brightness: BrightnessActivitySource
    private let volume: VolumeActivitySource

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustPollTimer: Timer?
    private var promptedForAccess = false

    nonisolated private static let normalStep: Float = 1.0 / 16.0
    nonisolated private static let fineStep: Float = 1.0 / 64.0

    nonisolated private static let NX_KEYTYPE_SOUND_UP: Int32 = 0
    nonisolated private static let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
    nonisolated private static let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
    nonisolated private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
    nonisolated private static let NX_KEYTYPE_MUTE: Int32 = 7

    /// System-defined event type. CGEventType has no public case for this
    /// (rawValue 14), so we force-unwrap once at type level.
    nonisolated private static let systemDefined = CGEventType(rawValue: 14)!

    /// Singleton-style weak reference so the C tap callback can hop back
    /// to the live instance without retaining it.
    nonisolated(unsafe) private static weak var active: MediaKeySuppressor?

    init(brightness: BrightnessActivitySource, volume: VolumeActivitySource) {
        self.brightness = brightness
        self.volume = volume
    }

    func start() {
        Self.active = self
        if installTap() { return }
        if !promptedForAccess { promptForAccessibility() }
        startTrustPolling()
    }

    func stop() {
        teardownTap()
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        if Self.active === self { Self.active = nil }
    }

    // MARK: - Tap lifecycle

    private func installTap() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask = 1 << Self.systemDefined.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                guard let suppressor = MediaKeySuppressor.active else {
                    return Unmanaged.passUnretained(event)
                }
                return suppressor.handleNonisolated(type: type, event: event)
            },
            userInfo: nil
        ) else {
            NSLog("[MediaKeys] tapCreate returned nil despite AX trust — giving up")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        NSLog("[MediaKeys] suppression tap installed")
        return true
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Trust handling

    private func promptForAccessibility() {
        promptedForAccess = true

        // Triggers the system prompt and registers the app under Accessibility.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let alert = NSAlert()
        alert.messageText = "NotchApp needs Accessibility access"
        alert.informativeText = """
            To suppress the macOS brightness/volume HUD and show the notch \
            ribbon instead, enable NotchApp in System Settings → Privacy & \
            Security → Accessibility.

            The app keeps working without this — you'll just see both the \
            system HUD and the notch ribbon.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func startTrustPolling() {
        guard trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.installTap() {
                    self.trustPollTimer?.invalidate()
                    self.trustPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    // MARK: - Event handling

    /// Called from the CGEvent tap thread. We only need MainActor for the
    /// adjust/toggle calls — everything else here is pure parsing.
    nonisolated private func handleNonisolated(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let tap = self?.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemDefined else { return Unmanaged.passUnretained(event) }

        // Parse via NSEvent for the canonical subtype/data1 read. The raw
        // CGEventField path mew uses returns garbage for non-aux subtypes.
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let keyCode = Int32((data1 >> 16) & 0xFFFF)
        let keyFlags = data1 & 0xFFFF
        let stateNibble = (keyFlags & 0xFF00) >> 8
        let isKeyDown = stateNibble == 0xA
        let isKeyUp = stateNibble == 0xB

        switch keyCode {
        case Self.NX_KEYTYPE_SOUND_UP,
             Self.NX_KEYTYPE_SOUND_DOWN,
             Self.NX_KEYTYPE_MUTE,
             Self.NX_KEYTYPE_BRIGHTNESS_UP,
             Self.NX_KEYTYPE_BRIGHTNESS_DOWN:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        if isKeyDown {
            let flags = event.flags
            let fine = flags.contains(.maskShift) && flags.contains(.maskAlternate)
            let step = fine ? Self.fineStep : Self.normalStep
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(keyCode: keyCode, step: step)
                }
            }
            return nil
        }
        if isKeyUp {
            // Swallow the matching keyUp so nothing downstream sees a
            // dangling release for an event we already consumed.
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func apply(keyCode: Int32, step: Float) {
        switch keyCode {
        case Self.NX_KEYTYPE_SOUND_UP:        volume.adjust(by: +step)
        case Self.NX_KEYTYPE_SOUND_DOWN:      volume.adjust(by: -step)
        case Self.NX_KEYTYPE_MUTE:            volume.toggleMute()
        case Self.NX_KEYTYPE_BRIGHTNESS_UP:   brightness.adjust(by: +step)
        case Self.NX_KEYTYPE_BRIGHTNESS_DOWN: brightness.adjust(by: -step)
        default: break
        }
    }
}
