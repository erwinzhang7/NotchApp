import SwiftUI

/// One displayable activity in the idle notch — charging, bluetooth
/// connection, now-playing, etc. Lean version of DynamicNotch's
/// `NotchContentProtocol`: no expand-on-tap, no window links, no stroke
/// colors. Activities are pure compact ribbons that grow from the base
/// idle pill size.
///
/// NOT @MainActor on the protocol itself so the model that owns it can
/// expose computed properties (id, size) from nonisolated contexts.
/// Only `makeView()` requires main-actor isolation, since SwiftUI view
/// construction does.
protocol NotchActivity: Sendable {
    /// Stable identity. Same id = "same activity" (updates replace, don't
    /// stack). Two activities with the same id never coexist.
    var id: String { get }

    /// Priority arbitrates which live activity wins the screen when more
    /// than one is active. Higher wins.
    var priority: Int { get }

    /// Compact size relative to the idle pill's base size. Most activities
    /// extend `baseWidth` horizontally; some grow vertically too.
    func size(base: CGSize) -> CGSize

    /// Compact content. Renders inside the inward-notch silhouette,
    /// clipped to the activity's `size(base:)`.
    @MainActor @ViewBuilder func makeView() -> AnyView
}

/// Fixed priorities — small integer ladder. No UserDefaults overrides, no
/// per-key registries; one source of truth that the three activity sources
/// reference directly.
enum NotchActivityPriority {
    static let nowPlaying = 6
    static let bluetooth = 4
    static let power = 3
}
