import AppKit
import CoreGraphics

/// Persistent identifier for an `NSScreen` derived from
/// `CGDisplayCreateUUIDFromDisplayID`. Stable across reboots, cable swaps,
/// and across user accounts on the same hardware — unlike
/// `CGDirectDisplayID`, which is reassigned every session.
///
/// Pattern lifted from boring.notch's `NSScreen+UUID.swift`. The cache
/// observes `didChangeScreenParameters` so a hot-plug refresh is automatic.
extension NSScreen {
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    @MainActor static func screen(withUUID uuid: String) -> NSScreen? {
        NSScreenUUIDCache.shared.screen(forUUID: uuid)
    }

    @MainActor static var screensByUUID: [String: NSScreen] {
        NSScreenUUIDCache.shared.allScreens
    }
}

@MainActor
final class NSScreenUUIDCache {
    static let shared = NSScreenUUIDCache()

    private var cache: [String: NSScreen] = [:]
    private var observer: Any?

    private init() {
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func rebuild() {
        var next: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let uuid = screen.displayUUID { next[uuid] = screen }
        }
        cache = next
    }

    func screen(forUUID uuid: String) -> NSScreen? { cache[uuid] }
    var allScreens: [String: NSScreen] { cache }
}
