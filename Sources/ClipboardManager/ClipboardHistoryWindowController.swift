import AppKit
import SwiftUI

/// AppKit window wrapper around ClipboardHistoryView. The notch shell will eventually present
/// the SwiftUI view directly; this window lets the status-bar launcher show it in the meantime.
@MainActor
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            AccessoryWindowPresenter.managedWindowClosed(window)
            return
        }
        show()
    }

    func show() {
        if let window {
            AccessoryWindowPresenter.present(window)
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

        AccessoryWindowPresenter.present(win)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller alive; the next show() reuses the window.
        // Drop the activation policy back to .accessory if this was the
        // last managed window on screen.
        if let window {
            AccessoryWindowPresenter.managedWindowClosed(window)
        }
    }
}
