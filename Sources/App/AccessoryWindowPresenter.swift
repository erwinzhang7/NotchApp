import AppKit

extension NSUserInterfaceItemIdentifier {
    /// Tags the regular windows NotchApp owns (Settings, Clipboard History)
    /// so the presenter can tell when the last one has closed.
    static let notchManagedWindow = NSUserInterfaceItemIdentifier("com.erwinzhang.NotchApp.managedWindow")
}

/// Presents a normal window from this LSUIElement (accessory) agent.
///
/// Showing a window from an accessory app is unreliable on macOS 26 when
/// the app isn't already the active app: `NSApp.activate(...)` +
/// `makeKeyAndOrderFront` leave the window created-but-not-foregrounded.
/// That's why Settings / History opened fine from the menu-bar icon (whose
/// click activates the app) but did nothing from the non-activating notch
/// panel's right-click menu — the app stayed inactive.
///
/// Briefly promoting the activation policy to `.regular` while any managed
/// window is open guarantees the window appears and can take focus; we drop
/// back to `.accessory` once the last managed window closes, so there's no
/// lingering Dock icon.
@MainActor
enum AccessoryWindowPresenter {
    static func present(_ window: NSWindow) {
        window.identifier = .notchManagedWindow
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Call when a managed window closes or is hidden. Reverts to
    /// `.accessory` only once no other managed window remains on screen.
    static func managedWindowClosed(_ window: NSWindow) {
        let othersOpen = NSApp.windows.contains {
            $0 !== window && $0.isVisible && $0.identifier == .notchManagedWindow
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
