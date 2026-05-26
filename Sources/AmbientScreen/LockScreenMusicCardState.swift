import Combine
import Foundation

/// Shared state between LockScreenMusicCardView and the (separate)
/// backdrop panel. The card flips `isArtworkLifted` on artwork tap; the
/// backdrop watches the same flag to fade its blurred-art + accent tint
/// in and out of view.
@MainActor
final class LockScreenMusicCardState: ObservableObject {
    @Published var isArtworkLifted: Bool = false {
        didSet {
            NSLog("[Toggle] cardState.isArtworkLifted %@->%@",
                  oldValue ? "Y" : "N",
                  isArtworkLifted ? "Y" : "N")
        }
    }

    /// True while the user is actively typing — keystroke happened
    /// within the last ~3s. Driven by a poll in
    /// LockScreenMusicWidgetController. When true, the backdrop fades
    /// away so the macOS login user-icon + password field underneath
    /// becomes visible. Trackpad / mouse activity does NOT flip this.
    @Published var keyboardActive: Bool = false
}
