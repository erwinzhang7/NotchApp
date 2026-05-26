import Combine
import Foundation

/// Toggle that drives whether the notch's now-playing activity shows
/// the equalizer (default) or the lyrics scroller. Flipped by tapping
/// the artwork inside the activity view; no settings UI. Persists for
/// the app session — not across launches and not per-track.
///
/// Shared singleton so both the activity (which renders based on it)
/// and the bridge (which rebuilds the activity + registers as a lyrics
/// consumer when it changes) can observe the same source of truth.
@MainActor
final class NotchLyricsToggleState: ObservableObject {
    static let shared = NotchLyricsToggleState()

    @Published var enabled: Bool = false

    private init() {}
}
