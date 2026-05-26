import Foundation

/// Lyrics document for a single track. `trackKey` is the cache key the
/// service used to fetch this entry — store it so lookups can short-circuit
/// repeat fetches of the same playing track. Ported from DynamicNotch.
struct TrackLyrics: Equatable, Sendable {
    let trackKey: String
    let lines: [LyricLine]
    let isSynced: Bool

    /// Index of the line that should be visually active at `elapsedTime`.
    /// 0.18s look-ahead matches DynamicNotch: most LRC files anchor each
    /// line at the moment the singer starts the syllable, so a tiny
    /// lead-time makes the highlight feel synchronized rather than late.
    /// Returns nil for unsynced lyrics.
    func activeLineIndex(at elapsedTime: TimeInterval) -> Int? {
        guard isSynced, lines.isEmpty == false else { return nil }
        let playbackPosition = elapsedTime + 0.18
        return lines.lastIndex { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= playbackPosition
        } ?? 0
    }
}
