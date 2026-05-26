import Combine
import Foundation

/// Observes `NowPlayingState`, debounces track-identity changes, and
/// drives the LRCLIB provider. On-demand: only fetches when at least one
/// consumer is registered as active (the lock-screen lyrics column or
/// the notch's tap-to-toggle artwork view). With no consumers, the
/// service stays quiet — no network calls.
///
/// Consumers register themselves with stable string keys via
/// `setConsumer(_:active:)`. The service refcounts active keys; when the
/// set transitions empty → non-empty it kicks off a fetch for the
/// currently-playing track. When it transitions back to empty it
/// cancels any in-flight task and drops cached state.
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var state: NowPlayingLyricsState = .idle
    @Published private(set) var lyrics: TrackLyrics?

    private let nowPlaying: NowPlayingState
    private let provider: LRCLIBLyricsProvider
    private var cancellables = Set<AnyCancellable>()
    private var inFlight: Task<Void, Never>?
    private var lastQuery: LyricsTrackQuery?
    /// Refcount-style consumer set. Each consumer's `setConsumer` call
    /// adds or removes its key; fetching only happens while the set is
    /// non-empty. Using a Set lets the same consumer call setConsumer
    /// repeatedly without breaking the count.
    private var activeConsumers: Set<String> = []

    init(nowPlaying: NowPlayingState, provider: LRCLIBLyricsProvider? = nil) {
        self.nowPlaying = nowPlaying
        // Default-argument expressions are non-isolated, so we can't
        // construct the @MainActor-isolated provider in the parameter
        // list. Build it here instead — the init itself is @MainActor.
        self.provider = provider ?? LRCLIBLyricsProvider()
    }

    /// Spin up subscriptions on the now-playing state. Fetches stay
    /// gated on `activeConsumers` — start() alone never triggers a
    /// network call.
    func start() {
        guard cancellables.isEmpty else { return }
        NSLog("[Lyrics] service.start()")

        // Identity fields: title / artist / album / duration. Debounced
        // (250ms) so the burst of @Published updates that arrives when
        // the adapter reports a new track collapses into one refresh.
        nowPlaying.$title
            .combineLatest(nowPlaying.$artist, nowPlaying.$album, nowPlaying.$duration)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 && lhs.3 == rhs.3
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] title, artist, album, duration in
                self?.handleTrackChange(title: title, artist: artist, album: album, duration: duration)
            }
            .store(in: &cancellables)

        // No-media → clear state regardless of consumer status. Saves a
        // stale .loaded sticking around after playback stops.
        nowPlaying.$hasMedia
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasMedia in
                guard let self, !hasMedia else { return }
                NSLog("[Lyrics] hasMedia=false, clearing state")
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
        activeConsumers.removeAll()
        lastQuery = nil
        state = .idle
        lyrics = nil
    }

    /// Register or unregister a consumer. Stable key per consumer
    /// (e.g. `"lockScreen"`, `"notch"`); idempotent. When the consumer
    /// set transitions from empty → non-empty, the service immediately
    /// kicks off a fetch for whatever's playing now.
    func setConsumer(_ key: String, active: Bool) {
        let wasFetchingEnabled = !activeConsumers.isEmpty

        if active {
            activeConsumers.insert(key)
        } else {
            activeConsumers.remove(key)
        }

        let isFetchingEnabled = !activeConsumers.isEmpty
        NSLog("[Lyrics] setConsumer key=%@ active=%@ consumers=[%@] transition=%@->%@",
              key,
              active ? "Y" : "N",
              activeConsumers.isEmpty ? "" : Array(activeConsumers).joined(separator: ","),
              wasFetchingEnabled ? "fetching" : "idle",
              isFetchingEnabled ? "fetching" : "idle")

        switch (wasFetchingEnabled, isFetchingEnabled) {
        case (false, true):
            // First consumer arrived — fetch the current track if there is one.
            kickOffFetchForCurrentTrack()

        case (true, false):
            // Last consumer left — cancel everything and drop cached
            // state. Lyrics will be re-fetched on next activation.
            inFlight?.cancel()
            inFlight = nil
            lastQuery = nil
            state = .idle
            lyrics = nil

        default:
            break
        }
    }

    /// Called from `start()`'s identity-change pipeline. Records the
    /// new query so the fetch path knows what to look for, but only
    /// actually fetches if at least one consumer is active.
    private func handleTrackChange(title: String, artist: String, album: String, duration: TimeInterval) {
        let query = LyricsTrackQuery(title: title, artist: artist, album: album, duration: duration)
        NSLog("[Lyrics] handleTrackChange title=%@ artist=%@ album=%@ dur=%.1f consumers=%d",
              title, artist, album, duration, activeConsumers.count)

        // No-op if identity hasn't really changed (the adapter
        // re-emits the same payload on playback-rate updates).
        if let lastQuery, lastQuery == query {
            NSLog("[Lyrics] handleTrackChange: identity unchanged, skipping")
            return
        }
        lastQuery = query

        guard !activeConsumers.isEmpty else {
            // No consumer cares yet — drop stale state but don't fetch.
            // The fetch will fire whenever a consumer becomes active.
            NSLog("[Lyrics] handleTrackChange: no active consumers, dropping state without fetch")
            inFlight?.cancel()
            inFlight = nil
            state = .idle
            lyrics = nil
            return
        }

        fetch(query: query)
    }

    /// On consumer activation, re-derive the current query from
    /// NowPlayingState and fetch if there's a real track. Distinct from
    /// the identity-change path so a consumer joining mid-track gets
    /// lyrics for what's playing, not whatever was playing on the last
    /// identity change.
    private func kickOffFetchForCurrentTrack() {
        NSLog("[Lyrics] kickOffFetchForCurrentTrack hasMedia=%@ title=%@ artist=%@ dur=%.1f",
              nowPlaying.hasMedia ? "Y" : "N",
              nowPlaying.title,
              nowPlaying.artist,
              nowPlaying.duration)
        guard nowPlaying.hasMedia else {
            NSLog("[Lyrics] kickOff: no media — skipping")
            return
        }
        let query = LyricsTrackQuery(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            duration: nowPlaying.duration
        )
        lastQuery = query
        fetch(query: query)
    }

    private func fetch(query: LyricsTrackQuery) {
        guard let trackKey = query.cacheKey else {
            NSLog("[Lyrics] fetch: no cacheKey (empty title/artist), skipping")
            inFlight?.cancel()
            inFlight = nil
            state = .idle
            lyrics = nil
            return
        }

        NSLog("[Lyrics] fetch START title=%@ artist=%@ album=%@ dur=%.1f",
              query.title, query.artist, query.album, query.duration)

        inFlight?.cancel()
        state = .loading(trackKey: trackKey)
        let provider = self.provider
        let fetchStart = Date()

        inFlight = Task { [weak self] in
            do {
                let result = try await provider.lyrics(for: query)
                let elapsed = Date().timeIntervalSince(fetchStart)
                guard !Task.isCancelled else {
                    NSLog("[Lyrics] fetch task cancelled after %.2fs", elapsed)
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Ignore late results for a query the user has
                    // already moved past — a slow response landing
                    // after a skip-next would otherwise overwrite the
                    // new track's lyrics.
                    guard self.lastQuery?.cacheKey == trackKey else {
                        NSLog("[Lyrics] fetch result discarded — track changed (key=%@) after %.2fs", trackKey, elapsed)
                        return
                    }
                    if let result {
                        NSLog("[Lyrics] fetch SUCCESS in %.2fs: %d lines, synced=%@",
                              elapsed, result.lines.count, result.isSynced ? "Y" : "N")
                        self.lyrics = result
                        self.state = .loaded(result)
                    } else {
                        NSLog("[Lyrics] fetch NOT FOUND in %.2fs (key=%@)", elapsed, trackKey)
                        self.lyrics = nil
                        self.state = .notFound(trackKey: trackKey)
                    }
                }
            } catch is CancellationError {
                NSLog("[Lyrics] fetch CancellationError after %.2fs", Date().timeIntervalSince(fetchStart))
                return
            } catch {
                let elapsed = Date().timeIntervalSince(fetchStart)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.lastQuery?.cacheKey == trackKey else { return }
                    NSLog("[Lyrics] fetch FAILED in %.2fs: %@", elapsed, String(describing: error))
                    self.lyrics = nil
                    self.state = .failed(trackKey: trackKey)
                }
            }
        }
    }
}
