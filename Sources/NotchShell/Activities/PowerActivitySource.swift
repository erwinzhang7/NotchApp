import Combine
import Foundation
import IOKit.ps

/// Wraps IOPowerSources notifications and converts them into a stream of
/// power events the engine can act on. Inspired by DynamicNotch's
/// `PowerService` but stripped: no DEBUG injection, no thresholds stored
/// in settings (hardcoded 20% / 80% bands), no low-power-mode tracking.
@MainActor
final class PowerActivitySource: ObservableObject {
    /// Latest snapshot of the internal battery. Republished so any UI
    /// that wants to render the actual level (the charging activity
    /// view does) can observe it.
    @Published private(set) var onACPower: Bool = false
    @Published private(set) var batteryLevel: Int = 0
    @Published private(set) var isCharging: Bool = false

    /// Hardcoded notification bands. Below 20% triggers low-power
    /// activity on the way down; reaching 80% triggers the "full" activity
    /// on the way up. Tuned to match what feels useful on the M5 Max
    /// without sitting in the notch every other minute.
    private static let lowPowerThreshold = 20
    private static let fullPowerThreshold = 80

    private var runLoopSource: CFRunLoopSource?
    private var previousOnACPower = false
    private var previousBatteryLevel = 0
    private var hasReadFirstSnapshot = false

    /// Fired whenever a notification-worthy threshold is crossed.
    /// Engine subscribes and decides whether to surface an activity.
    let events = PassthroughSubject<Event, Never>()

    enum Event: Equatable {
        case plugged          // AC just connected
        case lowPower         // crossed 20% on the way down (not on AC)
        case fullPower        // crossed 80% on the way up
    }

    func start() {
        guard runLoopSource == nil else { return }
        installNotifications()
        refresh()
    }

    func stop() {
        if let rls = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), rls, .defaultMode)
            runLoopSource = nil
        }
    }

    deinit {
        if let rls = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), rls, .defaultMode)
        }
    }

    private func installNotifications() {
        // IOPS callback fires from the run loop the source is added to.
        // We add it to the main run loop, so the callback context is
        // already on the main thread — but we still hop through DispatchQueue.main
        // to formalize MainActor isolation for Swift concurrency.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let source = Unmanaged<PowerActivitySource>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    source.refresh()
                }
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let rls = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .defaultMode)
        runLoopSource = rls
    }

    /// Read current IOPS state and emit threshold-crossing events.
    /// Skips emission on the very first read (otherwise plugging in at
    /// app launch would fire `.plugged` immediately).
    func refresh() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        var ac = false
        var level = 0
        var charging = false

        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any] else {
                continue
            }

            if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                ac = (state == kIOPSACPowerValue)
            }
            if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                level = Int((Double(current) / Double(max)) * 100.0)
            }
            if let ch = desc[kIOPSIsChargingKey as String] as? Bool {
                charging = ch
            }
            // First internal source wins — external UPS / wireless mouse
            // batteries are also reported here and would otherwise
            // override the MacBook's own.
            if let transport = desc[kIOPSTransportTypeKey as String] as? String,
               transport == kIOPSInternalType {
                break
            }
        }

        let clampedLevel = min(max(level, 0), 100)

        let previousAC = previousOnACPower
        let previousLevel = previousBatteryLevel

        onACPower = ac
        batteryLevel = clampedLevel
        isCharging = charging

        // Suppress all events until we've seen one full read — the
        // first read is just establishing baseline state.
        if !hasReadFirstSnapshot {
            hasReadFirstSnapshot = true
            previousOnACPower = ac
            previousBatteryLevel = clampedLevel
            return
        }

        if !previousAC && ac {
            events.send(.plugged)
        }

        if !ac, previousLevel > Self.lowPowerThreshold, clampedLevel <= Self.lowPowerThreshold {
            events.send(.lowPower)
        }

        if previousLevel < Self.fullPowerThreshold, clampedLevel >= Self.fullPowerThreshold {
            events.send(.fullPower)
        }

        previousOnACPower = ac
        previousBatteryLevel = clampedLevel
    }
}
