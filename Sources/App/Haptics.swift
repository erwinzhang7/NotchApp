import AppKit

/// Thin wrapper around `NSHapticFeedbackManager` so call sites don't have
/// to repeat the `defaultPerformer.perform(...)` boilerplate. Trackpad-only
/// — silently no-ops on machines without a Force Touch device.
enum Haptics {
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}
