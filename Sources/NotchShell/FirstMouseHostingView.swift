import AppKit
import SwiftUI

/// NSHostingView that accepts the first mouse click even when its window
/// isn't key. The notch panel is a non-activating NSPanel, so without this
/// the first click on any SwiftUI control (e.g. a Clip-tab row) gets
/// swallowed activating the panel instead of dispatching as a tap — the
/// user has to click twice. Right-click is unaffected because context menus
/// don't go through the first-mouse path.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
