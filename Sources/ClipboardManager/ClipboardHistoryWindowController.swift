import AppKit
import SwiftUI

/// AppKit window wrapper around ClipboardHistoryView. The notch shell will eventually present
/// the SwiftUI view directly; this window lets the status-bar launcher show it in the meantime.
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ClipboardHistoryView(store: store))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Clipboard History"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 380, height: 480))
        win.minSize = NSSize(width: 320, height: 280)
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller alive; just drop the window reference so the next show() rebuilds clean.
    }
}
