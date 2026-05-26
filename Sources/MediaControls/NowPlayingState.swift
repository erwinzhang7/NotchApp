import AppKit
import Foundation

/// Observable now-playing state. Driven by MediaRemoteAdapter (which writes
/// from the main actor); UI observes via @Published.
@MainActor
final class NowPlayingState: ObservableObject {
    /// True once we have received at least one valid (non-empty title) payload.
    /// When false the UI shows the idle state.
    @Published var hasMedia: Bool = false

    /// True if the Perl adapter never produced output and exited non-zero, or
    /// the bundled script/framework couldn't be located. The UI swaps to an
    /// "media access unavailable" idle state instead of "nothing playing".
    @Published var adapterAvailable: Bool = true

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""

    /// Decoded artwork. Kept across updates that don't carry artworkData so
    /// the UI doesn't flash blank when an unrelated metadata field changes.
    @Published var artwork: NSImage?

    /// Raw artwork bytes from the most recent payload. Published
    /// separately from `artwork` so consumers that need stable byte
    /// equality (the lock-screen backdrop blur cache) can dedup
    /// without re-encoding the NSImage. The adapter writes both
    /// atomically when it sees a new image and skips the write when
    /// bytes are unchanged — that's what suppresses spurious blur
    /// recomputes on mid-track re-emits.
    @Published var artworkData: Data?

    @Published var isPlaying: Bool = false {
        willSet {
            // Freeze projection on transition true→false. The adapter
            // only emits a fresh `elapsed` value when it actually
            // arrives from MediaRemote, which can be hundreds of ms
            // after the pause flag flips. Between those two events,
            // `projectedElapsed` would fall back to the stale `elapsed`
            // field (the last position reported *before* the pause)
            // and the lyrics view would visibly snap backward. By
            // computing the projection here — while isPlaying is still
            // true and `playbackRate` still reflects the playing rate —
            // and writing it into `elapsed`, the view continues to
            // show the correct paused position immediately.
            guard isPlaying, !newValue, lastElapsedUpdate != .distantPast else { return }
            let drift = Date().timeIntervalSince(lastElapsedUpdate) * playbackRate
            let projected = elapsed + drift
            elapsed = duration > 0 ? min(projected, duration) : projected
            lastElapsedUpdate = Date()
        }
    }
    @Published var playbackRate: Double = 1.0

    /// Elapsed/duration as last reported by the adapter. `lastElapsedUpdate`
    /// is the wall clock time we received that elapsed value; use
    /// `projectedElapsed` to get a live estimate without polling.
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var lastElapsedUpdate: Date = .distantPast

    @Published var bundleIdentifier: String = "" {
        didSet { handleBundleChange(from: oldValue, to: bundleIdentifier) }
    }

    /// True while the user is actively dragging the scrubber. The adapter
    /// suppresses elapsed-time updates from the stream during this window
    /// so the drag isn't fought by incoming position reports.
    @Published var isScrubbing: Bool = false

    /// Pin set immediately after the user releases a scrub. The displayed
    /// position is held at `target` (not live stream position) until the
    /// stream catches up — see seekConvergenceToleranceSeconds for what
    /// "catches up" means. Released either when the adapter sees a
    /// converged elapsed value, or by the safety timeout below.
    @Published private(set) var seekPin: SeekPin?

    struct SeekPin: Equatable {
        let target: Double
        let startedAt: Date
        let bundleId: String
    }

    private var seekPinTimeoutTask: Task<Void, Never>?

    /// Stream `elapsed` within this many seconds of the seek target counts
    /// as "the player has caught up", at which point the pin is released
    /// and live tracking resumes. 1.5s comfortably covers the wobble we
    /// see between MediaRemote and Spotify-via-AppleScript while still
    /// keeping spurious pre-seek-coincidence converges rare.
    static let seekConvergenceToleranceSeconds: Double = 1.5

    /// Hard cap on the post-seek pin. If convergence never happens (silent
    /// seek failure, source changed, etc.) the pin releases anyway so the
    /// bar can't get stuck. Logged distinctly from natural convergence.
    static let seekConvergenceTimeoutSeconds: Double = 2.5

    /// Estimate of the current playback position based on the last elapsed
    /// value plus wall-clock drift, capped at the duration. The adapter only
    /// emits elapsed updates on track change / pause / seek, so for steady
    /// playback we project locally rather than poll the bridge.
    var projectedElapsed: Double {
        guard isPlaying, lastElapsedUpdate != .distantPast else { return elapsed }
        let drift = Date().timeIntervalSince(lastElapsedUpdate) * playbackRate
        let projected = elapsed + drift
        if duration > 0 { return min(projected, duration) }
        return projected
    }

    /// Bundle IDs we've decided cannot seek. Default for any bundle is
    /// "supported" — a source is only added here after enough capability
    /// failures (see failureThresholdToMarkUnsupported) prove it. Lives in
    /// memory only.
    @Published private(set) var seekUnsupportedSources: Set<String> = []

    /// Per-bundle-ID consecutive capability-failure count. Successes reset
    /// to zero; a bundle is added to seekUnsupportedSources only when its
    /// count crosses the threshold. Permission failures don't increment.
    private var seekFailureCounts: [String: Int] = [:]

    /// Capability failures a source can accumulate before it's marked
    /// unsupported. > 1 so one transient miss doesn't disable a player
    /// that genuinely can seek — we need to see the rejection a couple of
    /// times before believing it. Deterministic rejecters (Podcasts) hit
    /// this threshold trivially; one-off hiccups don't.
    static let failureThresholdToMarkUnsupported = 2

    /// Whether the current source should accept a scrub. Default true for
    /// any bundle ID not yet in the unsupported set (including unknown).
    var canSeekCurrentSource: Bool {
        guard !bundleIdentifier.isEmpty else { return true }
        return !seekUnsupportedSources.contains(bundleIdentifier)
    }

    /// Called by the adapter when a routed seek succeeded. Resets the
    /// consecutive-failure counter for the source and clears any prior
    /// unsupported mark — recovery, in case a mark was set spuriously.
    func noteSeekSuccess(_ bundleId: String) {
        guard !bundleId.isEmpty else { return }
        seekFailureCounts[bundleId] = 0
        seekUnsupportedSources.remove(bundleId)
    }

    /// Called by the adapter when the player itself rejected the seek (a
    /// capability problem — Podcasts' "Failed to seek" via MediaRemote, or
    /// a non-permission AppleScript error). Increments the counter and
    /// marks unsupported once the threshold is crossed.
    ///
    /// IMPORTANT: do NOT call this for permission/auth failures
    /// (AppleScript -1743 / -1744). Those are recoverable — the user can
    /// grant Automation permission and the same seek would work. The
    /// adapter's routing layer is responsible for distinguishing.
    func noteSeekCapabilityFailure(_ bundleId: String) {
        guard !bundleId.isEmpty else { return }
        let count = (seekFailureCounts[bundleId] ?? 0) + 1
        seekFailureCounts[bundleId] = count
        if count >= Self.failureThresholdToMarkUnsupported {
            seekUnsupportedSources.insert(bundleId)
        }
    }

    /// When the playing source switches, drop the OUTGOING bundle's
    /// tracked state so the user can return to it later with a clean
    /// slate. Each source is judged on its own current behavior — a stale
    /// mark from earlier in the session shouldn't persist after the user
    /// has moved away and the source's circumstances may have changed.
    private func handleBundleChange(from oldId: String, to newId: String) {
        guard oldId != newId, !oldId.isEmpty else { return }
        seekFailureCounts.removeValue(forKey: oldId)
        seekUnsupportedSources.remove(oldId)
        // A pin bound to the source we just moved away from can no longer
        // converge — its target is meaningless on the new source.
        if let pin = seekPin, pin.bundleId == oldId {
            clearSeekPin()
        }
    }

    /// Pin the displayed position to a seek target. The adapter releases
    /// the pin when an incoming stream update has elapsed within
    /// `seekConvergenceToleranceSeconds` of `target`; if that never
    /// happens, the safety timeout (`seekConvergenceTimeoutSeconds`)
    /// releases it instead. View shows `pin.target` while pinned, so the
    /// thumb stays where the user dropped it regardless of how slow the
    /// chosen tier's round-trip is.
    func setSeekPin(target: Double, bundleId: String) {
        seekPinTimeoutTask?.cancel()
        seekPin = SeekPin(target: target, startedAt: Date(), bundleId: bundleId)
        seekPinTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.seekConvergenceTimeoutSeconds))
            guard !Task.isCancelled, let self else { return }
            if let pin = self.seekPin {
                let elapsed = Date().timeIntervalSince(pin.startedAt)
                NSLog("[MediaControls] seek pin timeout — releasing without convergence target=\(pin.target) waited=\(String(format: "%.2f", elapsed))s")
                self.seekPin = nil
            }
            self.seekPinTimeoutTask = nil
        }
    }

    /// Release the pin immediately. Called by the adapter on convergence,
    /// by `handleBundleChange` on source switch, and by the view when a
    /// new drag supersedes a pending pin.
    func clearSeekPin() {
        seekPinTimeoutTask?.cancel()
        seekPinTimeoutTask = nil
        seekPin = nil
    }
}
