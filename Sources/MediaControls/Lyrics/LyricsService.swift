import Combine
import Foundation

/// Observes `NowPlayingState`, debounces track-identity changes, and
/// drives the LRCLIB provider. **Always-on prefetch:** every track
/// change triggers a fetch regardless of whether any UI is currently
/// showing lyrics. The two-layer cache (memory + disk) means that
/// when the user later toggles the lyrics view, results are already
/// there. The cost — one LRCLIB request per played track — is
/// negligible against the UX win of "lyrics appear instantly when I
/// ask for them."
///
/// `setConsumer(_:active:)` is kept for API stability but no longer
/// gates fetching. It's effectively a no-op now; callers can ignore.
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
        lastQuery = nil
        state = .idle
        lyrics = nil
    }

    /// Vestigial. The service now prefetches unconditionally on track
    /// change, so consumer registration no longer gates anything.
    /// Kept as a no-op so existing call sites compile without churn;
    /// safe to remove in a future cleanup.
    func setConsumer(_ key: String, active: Bool) {}

    /// Surface the provider's disk-cache footprint for the settings
    /// UI's size indicator.
    func diskCacheSizeBytes() -> Int {
        provider.diskCacheSizeBytes()
    }

    /// Wipe the cache (memory + disk) AND drop currently-loaded
    /// lyrics so the view immediately reflects the cleared state.
    /// A fresh fetch for the playing track kicks off via the existing
    /// identity-change pipeline only on the next adapter update — so
    /// post-clear, the current track will re-fetch on its next
    /// debounced sink fire.
    func clearCache() {
        provider.clearCache()
        inFlight?.cancel()
        inFlight = nil
        lastQuery = nil
        state = .idle
        lyrics = nil
    }

    /// Fires on every meaningful track-identity change. Always
    /// prefetches: cache hits are free, cache misses cost one LRCLIB
    /// request which lands long before the user is likely to toggle
    /// lyrics on. Cleared state immediately on identity change so the
    /// view never shows stale data from the prior track.
    private func handleTrackChange(title: String, artist: String, album: String, duration: TimeInterval) {
        let query = LyricsTrackQuery(title: title, artist: artist, album: album, duration: duration)
        NSLog("[Lyrics] handleTrackChange title=%@ artist=%@ album=%@ dur=%.1f",
              title, artist, album, duration)

        // No-op if identity hasn't really changed (cacheKey-based
        // equality survives sub-second duration drift).
        if let lastQuery, lastQuery == query {
            NSLog("[Lyrics] handleTrackChange: identity unchanged, skipping")
            return
        }
        let hadPriorLyrics = (lyrics != nil)
        lastQuery = query

        // Identity actually changed. Drop everything from the prior
        // track NOW so the view re-evaluates with no lyrics on hand —
        // the loading-state view kicks in for the brief fetch window.
        inFlight?.cancel()
        inFlight = nil
        if hadPriorLyrics {
            NSLog("[Lyrics] handleTrackChange: identity changed, clearing prior lyrics")
        }
        lyrics = nil
        state = .idle

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
