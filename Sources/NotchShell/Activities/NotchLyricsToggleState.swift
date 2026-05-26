import Combine
import Foundation

/// Toggle that drives whether the expanded shell's now-playing pane
/// shows the regular controls (default) or the scrolling lyrics view.
/// Flipped by tapping the artwork inside the shell's `NowPlayingView`;
/// no settings UI. Persists for the app session — not across launches.
///
/// Shared singleton so the view that flips it, the view that reads it
/// to switch layout, and the AppDelegate (which registers the lyrics
/// service consumer) all observe the same source of truth.
@MainActor
final class NotchLyricsToggleState: ObservableObject {
    static let shared = NotchLyricsToggleState()

    @Published var enabled: Bool = false

    private init() {}
}
