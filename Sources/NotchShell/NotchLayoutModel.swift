import AppKit
import Combine

/// Reactive sizing model for the notch shell. Owned by NotchWindowController
/// and observed by NotchShellView. Made @Published so the dashboard can
/// reflow (toggling Calendar / Reminders on/off shrinks or grows the panel)
/// without having to rebuild the NSHostingView.
@MainActor
final class NotchLayoutModel: ObservableObject {
    /// Visible pill size at the notch — set by the screen geometry and
    /// doesn't change at runtime.
    let collapsedSize: CGSize

    /// Expanded surface size. Mutates when ambient toggles change the
    /// presence of the bottom (calendar / reminders) row.
    @Published var expandedSize: CGSize

    init(collapsedSize: CGSize, expandedSize: CGSize) {
        self.collapsedSize = collapsedSize
        self.expandedSize = expandedSize
    }
}
