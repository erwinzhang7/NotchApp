import AppKit

/// Measures the physical notch on the active screen and computes the panel frame.
enum NotchGeometry {
    /// Default panel size when the active display has no notch.
    static let fallbackSize = CGSize(width: 220, height: 32)

    struct Placement {
        /// Frame in screen coordinates (origin = bottom-left of the display).
        let frame: CGRect
        /// The screen the panel should attach to.
        let screen: NSScreen
        /// True if the screen has a hardware notch.
        let hasNotch: Bool
    }

    /// Picks the best screen and returns where the panel should sit.
    static func placement(for size: CGSize? = nil) -> Placement? {
        guard let screen = preferredScreen() else { return nil }

        let notchHeight = screen.safeAreaInsets.top
        let notchWidth = measuredNotchWidth(on: screen)

        if notchHeight > 0, let notchWidth, notchWidth > 0 {
            let panelSize = size ?? CGSize(width: notchWidth, height: notchHeight)
            let frame = CGRect(
                x: screen.frame.midX - panelSize.width / 2,
                y: screen.frame.maxY - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
            return Placement(frame: frame, screen: screen, hasNotch: true)
        }

        // No notch: pin to top-center of the screen, just below the menu bar.
        let panelSize = size ?? fallbackSize
        let menuBarHeight = NSStatusBar.system.thickness
        let frame = CGRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - menuBarHeight - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        return Placement(frame: frame, screen: screen, hasNotch: false)
    }

    /// Prefers the built-in notched display, otherwise the screen with the mouse, otherwise main.
    private static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main
    }

    /// Notch width = full screen width − left aux strip − right aux strip.
    /// Returns nil if the auxiliary areas are not reported by the system.
    private static func measuredNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }
}
