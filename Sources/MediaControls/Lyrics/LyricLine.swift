import Foundation

/// One line of a track's lyrics. `startTime` is nil for plain (unsynced)
/// lyrics; populated for LRC-style synced lyrics. Ported from DynamicNotch.
struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let startTime: TimeInterval?
    let text: String
}
