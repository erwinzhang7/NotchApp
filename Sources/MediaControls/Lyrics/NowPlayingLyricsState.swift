import Foundation

/// State machine for the lyrics service's view of the currently-playing
/// track. Ported from DynamicNotch. Consumers (eventually a lyrics view)
/// switch on this; for now it's only observed for ingestion verification.
enum NowPlayingLyricsState: Equatable, Sendable {
    case idle
    case loading(trackKey: String)
    case loaded(TrackLyrics)
    case notFound(trackKey: String)
    case failed(trackKey: String)

    var trackKey: String? {
        switch self {
        case .idle:
            return nil
        case .loading(let trackKey),
             .notFound(let trackKey),
             .failed(let trackKey):
            return trackKey
        case .loaded(let lyrics):
            return lyrics.trackKey
        }
    }
}
