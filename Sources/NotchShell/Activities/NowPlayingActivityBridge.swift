import Combine
import Foundation

/// Bridges NotchApp's existing `NowPlayingState` (driven by the bundled
/// MediaRemoteAdapter) into engine-compatible live-activity updates.
/// Cleaner than porting DynamicNotch's 800-line `NowPlayingViewModel`
/// because we already own the upstream state — this just maps it to
/// "show / update / hide" calls on the engine.
///
/// Also bridges `NotchLyricsToggleState`: when the user taps the
/// notch's artwork, the bridge rebuilds the activity with `showsLyrics`
/// flipped so the engine swaps in the new (different-sized) variant
/// AND registers/unregisters as a LyricsService consumer so fetches
/// stay on-demand.
@MainActor
final class NowPlayingActivityBridge: ObservableObject {
    let events = PassthroughSubject<Event, Never>()

    enum Event {
        case started(NowPlayingActivity)
        case updated(NowPlayingActivity)
        case stopped
    }

    private let nowPlaying: NowPlayingState
    private let lyrics: LyricsService
    private let toggle: NotchLyricsToggleState
    private var cancellables = Set<AnyCancellable>()
    private var wasActive = false
    private var lastTrackKey: String?
    /// Stable consumer key matching the lock-screen's. Same service
    /// refcounts both; lock screen is "lockScreen", we are "notch".
    private static let lyricsConsumerKey = "notch"

    init(
        nowPlaying: NowPlayingState,
        lyrics: LyricsService,
        toggle: NotchLyricsToggleState = .shared
    ) {
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.toggle = toggle
    }

    func start() {
        guard cancellables.isEmpty else { return }

        // Identity fields — collapse the @Published burst that arrives
        // when the adapter reports a new track into a single signal.
        nowPlaying.$title
            .combineLatest(nowPlaying.$artist, nowPlaying.$hasMedia, nowPlaying.$isPlaying)
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.recompute()
            }
            .store(in: &cancellables)

        // Artwork comes in separately and triggers the in-place update
        // path so the activity refreshes once the image decodes.
        nowPlaying.$artwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }
            .store(in: &cancellables)

        // Lyrics toggle — rebuilds the activity with the new size +
        // mode so the engine animates the pill resize. Also gates the
        // lyrics consumer registration: only fetch while the notch is
        // showing lyrics AND a now-playing session is active.
        toggle.$enabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.applyLyricsConsumer(enabled: enabled)
                self.recompute()
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        lyrics.setConsumer(Self.lyricsConsumerKey, active: false)
        if wasActive {
            wasActive = false
            lastTrackKey = nil
            events.send(.stopped)
        }
    }

    private func recompute() {
        guard nowPlaying.hasMedia, nowPlaying.isPlaying else {
            if wasActive {
                wasActive = false
                lastTrackKey = nil
                events.send(.stopped)
            }
            return
        }

        let snapshot = NowPlayingActivity.Snapshot(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            artwork: nowPlaying.artwork
        )
        let activity = NowPlayingActivity(
            snapshot: snapshot,
            showsLyrics: toggle.enabled
        )
        let trackKey = "\(snapshot.title)|\(snapshot.artist)"

        if !wasActive {
            wasActive = true
            lastTrackKey = trackKey
            events.send(.started(activity))
        } else if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            // New track within an active session — still .started
            // semantically so the engine re-runs the appear animation.
            events.send(.started(activity))
        } else {
            // Same track, refreshed payload (artwork landed, toggle
            // flipped, etc.). In-place update path on the engine, which
            // animates size changes when the activity grew/shrank for
            // lyrics mode.
            events.send(.updated(activity))
        }
    }

    /// Notch consumer is active only when: lyrics toggle is on AND
    /// a now-playing session exists. Otherwise unregister so the
    /// service can go idle when no consumer cares.
    private func applyLyricsConsumer(enabled: Bool) {
        let shouldFetch = enabled && nowPlaying.hasMedia
        lyrics.setConsumer(Self.lyricsConsumerKey, active: shouldFetch)
    }
}
