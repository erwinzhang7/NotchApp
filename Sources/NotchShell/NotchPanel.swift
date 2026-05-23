import AppKit

/// Borderless, non-activating NSPanel used as the notch surface.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // popUpMenu sits above the menu bar so the expanded panel doesn't get clipped by it.
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        worksWhenModal = true
        // Required for SwiftUI .onHover to fire while the panel is non-key.
        acceptsMouseMovedEvents = true
        // Only become key when an embedded view actually needs keystrokes (e.g. the
        // history search TextField). Plain mouse-down on rows leaves key state alone.
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        ignoresMouseEvents = false
    }

    // Allowed to become key (paired with becomesKeyOnlyIfNeeded so it's opt-in per click).
    // Combined with .nonactivatingPanel: getting key state does not pull the app to the
    // foreground — the underlying app stays "active" in the Cmd+Tab sense.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
