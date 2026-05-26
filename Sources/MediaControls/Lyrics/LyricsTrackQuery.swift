import Foundation

/// Minimal track identity used by the lyrics provider. NotchApp's
/// `NowPlayingState` is a long-lived ObservableObject; the provider just
/// needs a snapshot of the relevant identification fields plus duration
/// (used both as a search hint and as part of the cache key).
///
/// **Equality** is intentionally cacheKey-based, not field-by-field:
/// two queries that normalize to the same cacheKey (case/diacritic
/// differences, sub-second duration drift) compare equal so the
/// `LyricsService.lastQuery == query` short-circuit treats them as
/// the same track. Without this, MediaRemote-emitted duration jitter
/// (214.0 → 214.3 mid-track) was forcing the service to re-fetch even
/// though both queries map to the same LRCLIB result.
struct LyricsTrackQuery: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    /// Stable cache key. Tracks with identical normalized title + artist +
    /// album + rounded duration share a key, which means re-plays of the
    /// same song hit the in-memory cache instead of the network.
    var cacheKey: String? {
        let normalizedTitle = title.lyricsNormalized
        let normalizedArtist = artist.lyricsNormalized
        guard normalizedTitle.isEmpty == false, normalizedArtist.isEmpty == false else {
            return nil
        }
        return [
            normalizedTitle,
            normalizedArtist,
            album.lyricsNormalized,
            "\(Int(duration.rounded()))"
        ].joined(separator: "|")
    }

    static func == (lhs: LyricsTrackQuery, rhs: LyricsTrackQuery) -> Bool {
        // Both nil cacheKeys = both "no identifiable track" = treat
        // as equal so we don't endlessly re-attempt empty queries.
        switch (lhs.cacheKey, rhs.cacheKey) {
        case (nil, nil):
            return true
        case (let l?, let r?):
            return l == r
        default:
            return false
        }
    }
}

extension String {
    /// Case- and diacritic-insensitive normalization used for both cache
    /// keys and match scoring. The curly apostrophe rewrite catches the
    /// common case where Apple Music ships titles with `’` but LRCLIB has
    /// them with `'`.
    var lyricsNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Trimmed copy with leading / trailing whitespace and newlines stripped.
    var lyricsTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
