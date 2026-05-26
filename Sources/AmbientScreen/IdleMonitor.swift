import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Reports when the user has been idle (no HID input) for at least
/// `threshold` seconds, then again when activity resumes. Polls the
/// IOHIDSystem service every `pollInterval` seconds — cheap, system-wide,
/// works regardless of focused app or hidden menu bar.
@MainActor
final class IdleMonitor {
    /// Idle threshold in seconds; cross above → onIdle fires once;
    /// cross back below → onActive fires once.
    var threshold: TimeInterval

    var onIdle: (() -> Void)?
    var onActive: (() -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval
    private var wasIdle = false

    init(threshold: TimeInterval = 180, pollInterval: TimeInterval = 5) {
        self.threshold = threshold
        self.pollInterval = pollInterval
    }

    func start() {
        stop()
        // Tick once immediately so the initial state is correct, then poll.
        tick()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Timer is added to RunLoop.main below, so the callback
            // fires on the main thread already — but its closure
            // isn't typed @MainActor in the Timer API. Assert the
            // isolation we know we have (instead of the previous
            // extra DispatchQueue.main.async hop, which delayed each
            // tick by one runloop cycle for no good reason).
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force the next tick to fire onActive (called when we know activity
    /// happened — e.g. global mouse-moved monitor in the controller).
    func resetActivity() {
        if wasIdle {
            wasIdle = false
            onActive?()
        }
    }

    private func tick() {
        let idle = Self.systemIdleSeconds()
        var nowIdle = idle >= threshold
        // Even if HIDIdleTime is past the threshold, treat the Mac as
        // active when any IOKit assertion is preventing user-idle sleep
        // (caffeinate -d/-i, a running download in some apps, the user
        // explicitly declaring activity). Avoids the widget popping up
        // when the user has intentionally kept the screen on but isn't
        // touching the keyboard.
        if nowIdle, Self.hasPreventIdleAssertion() {
            nowIdle = false
        }
        if nowIdle != wasIdle {
            wasIdle = nowIdle
            if nowIdle { onIdle?() } else { onActive?() }
        }
    }

    /// True if something is explicitly preventing the **display** from
    /// sleeping — `caffeinate -d`, presentation mode, video players,
    /// "Prevent computer from sleeping" in System Settings. That's
    /// the signal of "the display is on for a reason, don't overlay
    /// the lock widget on top of it."
    ///
    /// We deliberately do NOT check `UserIsActive` or
    /// `PreventUserIdleSystemSleep` here, even though earlier
    /// revisions did. Music apps (Spotify, Apple Music) hold
    /// `UserIsActive` while a track plays so the system stays awake
    /// long enough to keep the audio pipeline alive. Gating on that
    /// would suppress the lock-screen widget every time music is
    /// playing — which is the exact scenario it's meant to surface
    /// in. Narrowing the check to `PreventUserIdleDisplaySleep`
    /// captures "display is being kept lit on purpose" without
    /// false-positive-suppressing during regular playback.
    static func hasPreventIdleAssertion() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsStatus(&raw)
        guard result == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [String: Int]
        else { return false }
        return (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }

    /// Seconds since last HID event. Returns 0 if the service is
    /// unavailable (effectively "always active").
    static func systemIdleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOHIDSystem")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS,
              iterator != 0 else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let idleNs = dict["HIDIdleTime"] as? UInt64 else { return 0 }
        return TimeInterval(idleNs) / 1_000_000_000
    }
}
