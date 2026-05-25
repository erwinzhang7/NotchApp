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
            // Timer callback isn't @MainActor-typed; hop back.
            DispatchQueue.main.async { self?.tick() }
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

    /// True if any active assertion is preventing user-idle sleep or
    /// declaring the user active. `caffeinate -d` creates
    /// `PreventUserIdleDisplaySleep`; `-i` creates
    /// `PreventUserIdleSystemSleep`; `-u` (and many APIs that ping for
    /// activity) create `UserIsActive`.
    static func hasPreventIdleAssertion() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsStatus(&raw)
        guard result == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [String: Int]
        else { return false }
        let blockers = [
            "PreventUserIdleSystemSleep",
            "PreventUserIdleDisplaySleep",
            "UserIsActive",
        ]
        return blockers.contains { (dict[$0] ?? 0) > 0 }
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
