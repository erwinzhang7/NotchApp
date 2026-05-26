import SwiftUI

/// Ported from DynamicNotch's `NotchAnimations` (balanced preset only —
/// NotchApp doesn't ship the 5-preset settings picker; hardcoded for the
/// MacBook Pro target). Use these for any idle-notch / live-activity-style
/// animations so the feel matches the reference implementation.
enum NotchAnimations {
    /// Default spring used while content morphs in place.
    static let contentUpdate: Animation = .spring(response: 0.47)
    /// Spring used when notch content (or the surface itself) hides.
    static let contentHide: Animation = .spring(response: 0.47, dampingFraction: 0.8)
    /// Spring used when notch content (or the surface itself) appears.
    /// Slightly looser damping than `contentHide` so entries feel lively.
    static let contentShow: Animation = .spring(response: 0.47, dampingFraction: 0.7)
    /// Asymmetric content transition (compact ↔ expanded variants of the
    /// same activity). Slightly longer response than contentShow.
    static let openContentTransition: Animation = .spring(response: 0.50, dampingFraction: 0.7)
    /// Notch geometry change when a live activity expands.
    static let expandLiveActivity: Animation = .spring(response: 0.40, dampingFraction: 0.8)
    /// Content transition synchronized with the expand-live-activity geometry.
    static let expandLiveActivityContentTransition: Animation = .spring(response: 0.45, dampingFraction: 0.8)
    /// Reset spring after a swipe-stretch interaction ends.
    static let stretchReset: Animation = .spring(response: 0.47)
    /// Stroke (border) fade in / out when content first appears or fully clears.
    static let strokeVisibility: Animation = .spring(response: 0.47)
    /// Notch surface itself appearing / disappearing.
    static let notchVisibility: Animation = .spring(response: 0.47)

    /// Beat to wait between hiding one activity and showing the next so
    /// the spring re-entries don't visually overlap.
    static let hideShowDelay: TimeInterval = 0.35
    /// Beat between queued activities so they don't pile up.
    static let queuePacingDelay: TimeInterval = 0.1
}
