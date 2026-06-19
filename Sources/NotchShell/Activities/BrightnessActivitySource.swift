import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

/// Watches the internal panel brightness only. External displays do not
/// correspond to the physical-notch activity surface.
@MainActor
final class BrightnessActivitySource: ObservableObject {
    let events = PassthroughSubject<Int, Never>()

    private typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32
    private typealias RegisterFunction = @convention(c) (
        CGDirectDisplayID,
        CGDirectDisplayID,
        CFNotificationCallback?
    ) -> Int32
    private typealias UnregisterFunction = @convention(c) (
        CGDirectDisplayID,
        CGDirectDisplayID
    ) -> Int32

    private static weak var activeSource: BrightnessActivitySource?
    private static let brightnessCallback: CFNotificationCallback = { _, _, _, _, _ in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                activeSource?.refresh(emit: true)
            }
        }
    }

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightnessFunction?
    private var setBrightness: SetBrightnessFunction?
    private var register: RegisterFunction?
    private var unregister: UnregisterFunction?
    private var displayID: CGDirectDisplayID?
    private var previousLevel: Int?
    private var screenObserver: NSObjectProtocol?

    /// Wall-clock time of the last user-initiated brightness change
    /// (i.e., MediaKeySuppressor calling `adjust(by:)` from a key press).
    /// Changes that arrive outside this window — ambient-light auto-
    /// adjustments, Touch Bar slider, Control Center, AppleScript — are
    /// applied to `previousLevel` silently but don't surface the
    /// activity ribbon. Keeps the notch quiet during the continuous
    /// micro-nudges the ambient light sensor produces.
    private var lastUserAdjustAt: Date?
    private let userIntentWindow: TimeInterval = 1.5

    func start() {
        guard displayID == nil, let builtInDisplayID = Self.builtInDisplayID() else { return }

        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness"),
              let registerSymbol = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let unregisterSymbol = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications") else {
            dlclose(handle)
            return
        }

        let getter = unsafeBitCast(getSymbol, to: GetBrightnessFunction.self)
        let setter = unsafeBitCast(setSymbol, to: SetBrightnessFunction.self)
        let register = unsafeBitCast(registerSymbol, to: RegisterFunction.self)
        let unregister = unsafeBitCast(unregisterSymbol, to: UnregisterFunction.self)

        frameworkHandle = handle
        getBrightness = getter
        setBrightness = setter
        self.register = register
        self.unregister = unregister
        displayID = builtInDisplayID
        Self.activeSource = self

        guard register(builtInDisplayID, builtInDisplayID, Self.brightnessCallback) == 0 else {
            stop()
            return
        }
        installScreenObserver()
        refresh(emit: false)
    }

    /// Re-point the registered display after a hot-plug. Display IDs are
    /// reassigned across reconnects, so a cached ID can come to refer to a
    /// different (e.g. external) display — reads would then report the wrong
    /// panel and the change callback would stop firing. Re-resolve the
    /// built-in and move the registration to it (dropping it entirely when
    /// no built-in is present, e.g. clamshell).
    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileDisplay() }
        }
    }

    private func reconcileDisplay() {
        let current = Self.builtInDisplayID()
        guard current != displayID else { return }
        if let old = displayID { _ = unregister?(old, old) }
        displayID = current
        previousLevel = nil
        if let current, let register {
            _ = register(current, current, Self.brightnessCallback)
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let displayID {
            _ = unregister?(displayID, displayID)
        }
        if Self.activeSource === self {
            Self.activeSource = nil
        }
        displayID = nil
        getBrightness = nil
        setBrightness = nil
        register = nil
        unregister = nil
        previousLevel = nil
        if let frameworkHandle {
            dlclose(frameworkHandle)
            self.frameworkHandle = nil
        }
    }

    deinit {
        if let displayID {
            _ = unregister?(displayID, displayID)
        }
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    /// Apply a delta to the built-in display brightness, clamped to [0, 1].
    /// Triggers our own registered callback in turn, which surfaces the
    /// activity ribbon via the normal `events` path. Stamps
    /// `lastUserAdjustAt` so the callback knows this change is
    /// user-initiated and worth showing.
    func adjust(by delta: Float) {
        guard let getBrightness, let setBrightness else { return }
        // Re-resolve the built-in display on every call. Display IDs are
        // reassigned across hot-plug, and writing to a stale/recycled ID can
        // land on an external monitor — e.g. driving a Studio Display to
        // zero. If no built-in is currently present (clamshell), do nothing.
        guard let displayID = Self.builtInDisplayID() else { return }
        var current: Float = 0
        guard getBrightness(displayID, &current) == 0, current.isFinite else { return }
        let next = min(max(current + delta, 0), 1)
        lastUserAdjustAt = Date()
        if next == current {
            // Already pinned at the boundary (0% / 100%): setBrightness is
            // a no-op so the DisplayServices change callback never fires,
            // and `refresh` would dedup against `previousLevel` anyway. Emit
            // the ribbon directly so repeated key presses at the limit keep
            // flashing the current level instead of going silent.
            events.send(min(max(Int((current * 100).rounded()), 0), 100))
            return
        }
        _ = setBrightness(displayID, next)
    }

    private func refresh(emit: Bool) {
        guard let displayID, let getBrightness else { return }
        var brightness: Float = 0
        guard getBrightness(displayID, &brightness) == 0, brightness.isFinite else { return }

        let level = min(max(Int((brightness * 100).rounded()), 0), 100)
        guard level != previousLevel else { return }
        previousLevel = level
        guard emit else { return }
        // Suppress the activity for non-user-initiated changes (ambient
        // light sensor auto-adjust most commonly; also Touch Bar /
        // Control Center / AppleScript brightness slider moves). The
        // ribbon would otherwise flicker constantly under varying
        // lighting conditions.
        let recent = lastUserAdjustAt.map { Date().timeIntervalSince($0) < userIntentWindow } ?? false
        guard recent else { return }
        events.send(level)
    }

    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}
