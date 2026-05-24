import AppKit
import SwiftUI

/// Hosts SettingsView in a regular NSWindow controlled by AppDelegate.
///
/// We don't rely on the SwiftUI `Settings { … }` scene because invoking it
/// programmatically from an LSUIElement (accessory) agent is unreliable on
/// macOS 26 — `NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, …)`
/// walks the responder chain starting from a key window that doesn't exist
/// yet, so the action silently no-ops. Owning the window directly side-steps
/// the whole SwiftUI-runtime dispatch question and matches the pattern
/// `ClipboardHistoryWindowController` already uses.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Show the window. Creates it on first call, brings to front on
    /// subsequent calls. Activates the app explicitly because accessory
    /// apps don't get key/main automatically — without this the window
    /// can open behind other apps with no focus.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "NotchApp Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 520, height: 520))
        win.minSize = NSSize(width: 480, height: 420)
        // Keep the window object alive across closes so SwiftUI view state
        // (selected tab, scroll positions) persists between visits.
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // No-op. With isReleasedWhenClosed = false the window stays around
        // hidden; the next show() just re-orders it front.
    }
}
