import AppKit

/// Measures the physical notch on the active screen and computes the panel + visible sizes.
enum NotchGeometry {
    /// Visible collapsed size when the active display has no notch.
    static let fallbackCollapsedSize = CGSize(width: 200, height: 32)

    /// Visible size of the expanded surface. Sized for the clipboard history list:
    /// search field + ~6 visible rows + padding.
    static let defaultExpandedSize = CGSize(width: 480, height: 400)

    /// Extra hit-region around the visible surface so hover is forgiving.
    /// Must stay in sync with NotchShellView.hoverSlop.
    static let hoverSlop: CGFloat = 5

    /// Extra room around the visible surface so spring overshoot isn't clipped.
    static let breathingRoom = CGSize(width: 16, height: 16)

    struct Placement {
        /// Frame for the NSPanel itself, in screen coordinates.
        let panelFrame: CGRect
        /// Visible size when collapsed (matches the notch on notched displays).
        let collapsedSize: CGSize
        /// Visible size when expanded.
        let expandedSize: CGSize
        /// Screen the panel attaches to.
        let screen: NSScreen
        /// True if the screen has a hardware notch.
        let hasNotch: Bool
    }

    static func placement(expandedSize: CGSize = defaultExpandedSize) -> Placement? {
        guard let screen = preferredScreen() else { return nil }

        let notchHeight = screen.safeAreaInsets.top
        let measuredWidth = measuredNotchWidth(on: screen)
        let hasNotch = notchHeight > 0 && (measuredWidth ?? 0) > 0

        let collapsedSize: CGSize
        let panelTopY: CGFloat
        if hasNotch, let width = measuredWidth {
            collapsedSize = CGSize(width: width, height: notchHeight)
            // Panel top sits right at the screen top, so the collapsed pill aligns with the notch.
            panelTopY = screen.frame.maxY
        } else {
            collapsedSize = fallbackCollapsedSize
            // No notch: drop below the menu bar.
            panelTopY = screen.frame.maxY - NSStatusBar.system.thickness
        }

        let panelWidth = max(collapsedSize.width, expandedSize.width)
            + hoverSlop * 2
            + breathingRoom.width * 2
        let panelHeight = expandedSize.height + hoverSlop + breathingRoom.height

        let panelFrame = CGRect(
            x: screen.frame.midX - panelWidth / 2,
            y: panelTopY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        return Placement(
            panelFrame: panelFrame,
            collapsedSize: collapsedSize,
            expandedSize: expandedSize,
            screen: screen,
            hasNotch: hasNotch
        )
    }

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

    private static func measuredNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }
}
