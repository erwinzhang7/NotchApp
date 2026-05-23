import AppKit
import SwiftUI

/// Owns the notch panel: builds it, positions it under the notch, and re-positions on screen changes.
final class NotchWindowController: NSObject {
    private var panel: NotchPanel?
    private var screenObserver: NSObjectProtocol?

    func show() {
        guard let placement = NotchGeometry.placement() else { return }

        let panel = NotchPanel(contentRect: placement.frame)
        let hosting = NSHostingView(rootView: NotchShellView())
        hosting.frame = NSRect(origin: .zero, size: placement.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(placement.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    func hide() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func reposition() {
        guard let panel, let placement = NotchGeometry.placement() else { return }
        panel.setFrame(placement.frame, display: true)
    }
}
