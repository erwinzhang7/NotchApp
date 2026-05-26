import Combine
import Foundation

/// Observes `NowPlayingState`, debounces track-identity changes, and
/// drives the LRCLIB provider. Publishes `state` for downstream consumers;
/// no UI is wired up yet — this exists so lyrics are fetched and parsed
/// in the background and ready to display once a view exists.
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var state: NowPlayingLyricsState = .idle
    @Published private(set) var lyrics: TrackLyrics?

    private let nowPlaying: NowPlayingState
    private let provider: LRCLIBLyricsProvider
    private var cancellables = Set<AnyCancellable>()
    private var inFlight: Task<Void, Never>?
    private var lastQuery: LyricsTrackQuery?

    init(nowPlaying: NowPlayingState, provider: LRCLIBLyricsProvider? = nil) {
        self.nowPlaying = nowPlaying
        // Default-argument expressions are non-isolated, so we can't
        // construct the @MainActor-isolated provider in the parameter
        // list. Build it here instead — the init itself is @MainActor.
        self.provider = provider ?? LRCLIBLyricsProvider()
    }

    func start() {
        guard cancellables.isEmpty else { return }

        // Combine the four fields that define track identity. Debounce
        // (250ms) collapses the burst of @Published updates that arrives
        // when the adapter reports a new track — title, artist, album,
        // duration tend to update across a few main-loop cycles.
        nowPlaying.$title
            .combineLatest(nowPlaying.$artist, nowPlaying.$album, nowPlaying.$duration)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 && lhs.3 == rhs.3
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] title, artist, album, duration in
                self?.refresh(title: title, artist: artist, album: album, duration: duration)
            }
            .store(in: &cancellables)

        // Cover the case where the adapter never produces media (no
        // current player): drop to idle so the published state reflects
        // reality instead of a stale .loaded.
        nowPlaying.$hasMedia
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasMedia in
                guard let self, !hasMedia else { return }
                self.inFlight?.cancel()
                self.inFlight = nil
                self.lastQuery = nil
                self.state = .idle
                self.lyrics = nil
            }
            .store(in: &cancellables)
    }

    func stop() {
        inFlight?.cancel()
        inFlight = nil
        cancellables.removeAll()
        lastQuery = nil
        state = .idle
        lyrics = nil
    }

    private func refresh(title: String, artist: String, album: String, duration: TimeInterval) {
        let query = LyricsTrackQuery(title: title, artist: artist, album: album, duration: duration)

        // No-op if the relevant identity hasn't really changed (e.g. the
        // adapter re-emitted the same payload on a playback-rate update).
        if let lastQuery, lastQuery == query { return }
        lastQuery = query

        guard let trackKey = query.cacheKey else {
            inFlight?.cancel()
            inFlight = nil
            state = .idle
            lyrics = nil
            return
        }

        inFlight?.cancel()
        state = .loading(trackKey: trackKey)
        let provider = self.provider

        inFlight = Task { [weak self] in
            do {
                let result = try await provider.lyrics(for: query)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Ignore late results for a query the user has already
                    // moved past — guards against a slow response landing
                    // after the user skipped to the next track.
                    guard self.lastQuery?.cacheKey == trackKey else { return }
                    if let result {
                        self.lyrics = result
                        self.state = .loaded(result)
                    } else {
                        self.lyrics = nil
                        self.state = .notFound(trackKey: trackKey)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.lastQuery?.cacheKey == trackKey else { return }
                    self.lyrics = nil
                    self.state = .failed(trackKey: trackKey)
                }
            }
        }
    }
}
