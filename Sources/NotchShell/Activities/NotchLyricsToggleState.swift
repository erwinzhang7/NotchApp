import Combine
import Foundation

/// Toggle that drives whether the expanded shell's now-playing pane
/// shows the regular controls (default) or the scrolling lyrics view.
/// Flipped by tapping the artwork inside the shell's `NowPlayingView`;
/// no settings UI. Persisted to UserDefaults so the chosen state
/// survives relaunches.
///
/// Shared singleton so the view that flips it, the view that reads it
/// to switch layout, and the AppDelegate (which registers the lyrics
/// service consumer) all observe the same source of truth.
@MainActor
final class NotchLyricsToggleState: ObservableObject {
    static let shared = NotchLyricsToggleState()

    private static let defaultsKey = "notchShell.lyricsToggleEnabled"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            NSLog("[Lyrics] toggle %@->%@", oldValue ? "Y" : "N", enabled ? "Y" : "N")
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: [Self.defaultsKey: false])
        self.enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }
}
