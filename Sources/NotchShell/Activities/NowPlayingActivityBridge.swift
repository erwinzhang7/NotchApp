import Combine
import Foundation

/// Bridges NotchApp's existing `NowPlayingState` (driven by the bundled
/// MediaRemoteAdapter) into engine-compatible live-activity updates.
/// Cleaner than porting DynamicNotch's 800-line `NowPlayingViewModel`
/// because we already own the upstream state — this just maps it to
/// "show / update / hide" calls on the engine.
@MainActor
final class NowPlayingActivityBridge: ObservableObject {
    let events = PassthroughSubject<Event, Never>()

    enum Event {
        case started(NowPlayingActivity)
        case updated(NowPlayingActivity)
        case stopped
    }

    private let nowPlaying: NowPlayingState
    private var cancellables = Set<AnyCancellable>()
    private var wasActive = false
    private var lastTrackKey: String?

    init(nowPlaying: NowPlayingState) {
        self.nowPlaying = nowPlaying
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
    }

    func stop() {
        cancellables.removeAll()
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
        let activity = NowPlayingActivity(snapshot: snapshot)
        let trackKey = "\(snapshot.title)|\(snapshot.artist)"

        if !wasActive {
            wasActive = true
            lastTrackKey = trackKey
            events.send(.started(activity))
        } else if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            events.send(.started(activity))
        } else {
            events.send(.updated(activity))
        }
    }
}
