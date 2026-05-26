import Foundation

/// Minimal track identity used by the lyrics provider. NotchApp's
/// `NowPlayingState` is a long-lived ObservableObject; the provider just
/// needs a snapshot of the relevant identification fields plus duration
/// (used both as a search hint and as part of the cache key).
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
