import AppKit
import Foundation

/// AppleScript error codes that indicate a permission problem rather than
/// a player rejection. Treated as recoverable — we don't increment the
/// failure counter for these, so the source stays draggable while the user
/// is still resolving the Automation prompt.
///
/// File-scope so the background-queue closure that runs the script can
/// read it without inheriting MediaRemoteAdapter's @MainActor isolation.
private let appleScriptPermissionErrorCodes: Set<Int> = [
    -1743, // errAEEventNotPermitted — Automation permission denied or not yet granted
    -1744, // errAEEventWouldRequireUserConsent — older macOS consent flow
]

/// Manages the long-lived `mediaremote-adapter.pl stream` subprocess: spawn,
/// parse JSON-line stdout, restart on unexpected exit, terminate on quit.
/// Transport commands run as short-lived `send <id>` invocations.
///
/// The stream is invoked with `--no-diff` so every payload is a full snapshot,
/// avoiding diff-merge bookkeeping. Updates are infrequent (per track change /
/// pause / seek) so the artwork-repetition cost is negligible in practice.
@MainActor
final class MediaRemoteAdapter {
    private let state: NowPlayingState
    private var streamProcess: Process?
    private var stdoutBuffer = Data()
    private var restartTask: Task<Void, Never>?

    /// Tracks consecutive failed start attempts so we back off and eventually
    /// give up if the bundle is broken.
    private var consecutiveStartFailures: Int = 0
    private static let maxRestartAttempts = 3

    init(state: NowPlayingState) {
        self.state = state
    }

    deinit {
        // deinit cannot reach @MainActor methods directly; just terminate the
        // process synchronously. The Process API is thread-safe for terminate.
        if let process = streamProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard streamProcess == nil else { return }
        guard let scriptPath = Self.scriptPath, let frameworkPath = Self.frameworkPath else {
            state.adapterAvailable = false
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath, "stream", "--no-diff"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // stderr lines from the adapter are advisory per the README; drain
        // them so the buffer doesn't fill and stall the process.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            // FileHandle hands data on a background queue — hop to main for
            // buffer + state mutation.
            Task { @MainActor [weak self] in
                self?.appendStdout(data)
            }
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleProcessTerminated(exitStatus: status)
            }
        }

        do {
            try process.run()
            streamProcess = process
            consecutiveStartFailures = 0
        } catch {
            consecutiveStartFailures += 1
            state.adapterAvailable = false
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        if let process = streamProcess, process.isRunning {
            process.terminate()
        }
        streamProcess = nil
    }

    // MARK: - Transport commands

    /// Spawn a short-lived `send <id>` invocation. Fire and forget — the
    /// adapter applies the command and exits. We hold the Process in
    /// `transportProcesses` until it terminates: macOS keeps the child
    /// alive on its own, but the Process object owns the stdio pipes, and
    /// letting it deinit early can close them out from under the subprocess.
    func sendCommand(_ id: Int) {
        guard let scriptPath = Self.scriptPath, let frameworkPath = Self.frameworkPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath, "send", String(id)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        transportProcesses.append(process)
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.transportProcesses.removeAll { $0 === proc }
            }
        }
        do {
            try process.run()
        } catch {
            transportProcesses.removeAll { $0 === process }
        }
    }

    /// Strong references to in-flight transport subprocesses. Same rationale
    /// as `seekProcesses`: prevents the Process from deiniting before its
    /// stdio pipes are drained.
    private var transportProcesses: [Process] = []

    func play()              { sendCommand(0) }
    func pause()             { sendCommand(1) }
    func togglePlayPause()   { sendCommand(2) }
    func nextTrack()         { sendCommand(4) }
    func previousTrack()     { sendCommand(5) }

    // MARK: - Seek (per-source routing)

    /// Seek the now-playing source to an absolute position. Routes to one
    /// of three tiers based on the current bundle ID:
    ///
    /// - `com.spotify.client` → AppleScript (`set player position to`).
    ///   MediaRemote's set-elapsed-time path is silently ignored by Spotify;
    ///   the desktop app exposes the position through its Automation
    ///   dictionary instead. First call triggers the macOS automation
    ///   permission prompt — denial / dismissal counts as failure.
    /// - anything else → MediaRemote via the Perl bridge (microseconds).
    ///   Apple Music honours this; Apple Podcasts and many third-party
    ///   players reject it with `Failed to seek` on stderr.
    /// - on any failure the source is added to `seekUnsupportedSources`,
    ///   and the UI swaps the scrubber to display-only for that bundle ID.
    func seek(toSeconds seconds: Double) {
        let bundleId = state.bundleIdentifier
        guard !bundleId.isEmpty else {
            NSLog("[MediaControls] seek skipped: no current source")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let tier: SeekTier
            let outcome: SeekOutcome

            switch bundleId {
            case "com.spotify.client":
                tier = .spotifyAppleScript
                NSLog("[MediaControls] seek tier=spotify-applescript bundleId=\(bundleId) seconds=\(seconds)")
                outcome = await Self.seekSpotifyViaAppleScript(seconds: seconds)
            default:
                tier = .mediaRemote
                NSLog("[MediaControls] seek tier=mediaremote bundleId=\(bundleId) seconds=\(seconds)")
                outcome = await self.seekViaMediaRemote(seconds: seconds)
            }

            switch outcome {
            case .success:
                NSLog("[MediaControls] seek outcome=success tier=\(tier.rawValue) bundleId=\(bundleId)")
                self.state.noteSeekSuccess(bundleId)
            case .capabilityFailure(let detail):
                NSLog("[MediaControls] seek outcome=capability-failure tier=\(tier.rawValue) bundleId=\(bundleId) detail=\(detail) — incrementing failure count")
                self.state.noteSeekCapabilityFailure(bundleId)
            case .permissionFailure(let detail):
                // Recoverable — user just hasn't granted Automation access
                // yet (or denied this time and may grant later). Leave the
                // source's capability tracking untouched so the scrubber
                // stays draggable. The next attempt will trigger another
                // prompt (or succeed if the user has since granted).
                NSLog("[MediaControls] seek outcome=permission-failure tier=\(tier.rawValue) bundleId=\(bundleId) detail=\(detail) — source NOT marked unsupported")
            }
        }
    }

    private enum SeekTier: String {
        case spotifyAppleScript = "spotify-applescript"
        case mediaRemote = "mediaremote"
    }

    private enum SeekOutcome {
        case success
        /// The player rejected the seek itself (genuine capability problem).
        /// MediaRemote non-zero exit; non-permission AppleScript errors.
        case capabilityFailure(String)
        /// Auth/permission problem — the chosen tier couldn't even attempt
        /// the seek because the user hasn't granted access. Recoverable.
        case permissionFailure(String)
    }


    /// Tier 1: Spotify desktop via AppleScript. Player position is a real in
    /// SECONDS — distinct from the MediaRemote microsecond unit, intentionally
    /// not reusing the same value form.
    private static func seekSpotifyViaAppleScript(seconds: Double) async -> SeekOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<SeekOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let source = "tell application \"Spotify\" to set player position to \(seconds)"
                NSLog("[MediaControls] seek applescript source: \(source)")
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .capabilityFailure("NSAppleScript init returned nil"))
                    return
                }
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
                if let error = errorInfo as? [String: Any] {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let msg = (error[NSAppleScript.errorBriefMessage] as? String)
                        ?? (error[NSAppleScript.errorMessage] as? String)
                        ?? "unknown"
                    NSLog("[MediaControls] seek applescript error: code=\(code) msg=\(msg)")
                    if appleScriptPermissionErrorCodes.contains(code) {
                        cont.resume(returning: .permissionFailure("applescript code=\(code) msg=\(msg)"))
                    } else {
                        cont.resume(returning: .capabilityFailure("applescript code=\(code) msg=\(msg)"))
                    }
                } else {
                    cont.resume(returning: .success)
                }
            }
        }
    }

    /// Tier 2: MediaRemote via the Perl bridge. Same invocation that powers
    /// transport — but with `seek <micros>`. Non-zero exit (e.g. Podcasts'
    /// "Failed to seek to N") is reported as failure for capability tracking.
    private func seekViaMediaRemote(seconds: Double) async -> SeekOutcome {
        guard let scriptPath = Self.scriptPath, let frameworkPath = Self.frameworkPath else {
            return .capabilityFailure("bundle paths missing (script=\(Self.scriptPath ?? "nil"), framework=\(Self.frameworkPath ?? "nil"))")
        }
        let micros = max(0, Int(seconds * 1_000_000))
        let args = [scriptPath, frameworkPath, "seek", String(micros)]
        NSLog("[MediaControls] seek mediaremote launch: seconds=\(seconds) micros=\(micros) cmd=/usr/bin/perl \(args.joined(separator: " "))")

        return await withCheckedContinuation { (cont: CheckedContinuation<SeekOutcome, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = args
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] proc in
                let stdoutStr = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                       encoding: .utf8) ?? ""
                let stderrStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                       encoding: .utf8) ?? ""
                NSLog("[MediaControls] seek mediaremote exit: status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue) stdout=\"\(stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines))\" stderr=\"\(stderrStr.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                Task { @MainActor [weak self] in
                    self?.seekProcesses.removeAll { $0 === proc }
                }
                if proc.terminationStatus == 0 {
                    cont.resume(returning: .success)
                } else {
                    // MediaRemote has no permission model — non-zero exit
                    // here is always the player rejecting the seek itself.
                    let detail = "exit=\(proc.terminationStatus) stderr=\(stderrStr.trimmingCharacters(in: .whitespacesAndNewlines))"
                    cont.resume(returning: .capabilityFailure(detail))
                }
            }

            seekProcesses.append(process)
            do {
                try process.run()
                NSLog("[MediaControls] seek mediaremote spawned pid=\(process.processIdentifier)")
            } catch {
                NSLog("[MediaControls] seek mediaremote spawn failed: \(error.localizedDescription)")
                seekProcesses.removeAll { $0 === process }
                cont.resume(returning: .capabilityFailure("spawn failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Strong references to in-flight seek subprocesses. macOS keeps the
    /// child process alive independently, but the Process object owns the
    /// stdio pipes and the termination handler — letting it deinit early
    /// can drop both.
    private var seekProcesses: [Process] = []

    // MARK: - Stream parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        // Drain complete newline-terminated JSON lines from the buffer.
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard let update = try? JSONDecoder().decode(StreamUpdate.self, from: data) else { return }
        apply(update.payload)
    }

    private func apply(_ payload: StreamPayload) {
        // With --no-diff every payload is the complete current snapshot. An
        // empty payload (or one without a title) means nothing is playing.
        let title = payload.title ?? ""
        let isValid = !title.isEmpty

        state.hasMedia = isValid
        state.title = title
        state.artist = payload.artist ?? ""
        state.album = payload.album ?? ""
        state.duration = payload.duration ?? 0
        state.isPlaying = payload.playing ?? false
        state.playbackRate = payload.playbackRate ?? 1.0
        state.bundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
            ?? ""

        // Three modes for elapsed handling:
        //  1. Active drag (isScrubbing) — drop entirely; dragSeconds wins
        //     in the view. The stream would yank the thumb back mid-drag.
        //  2. Post-seek pin (seekPin) — drop UNTIL the stream's elapsed
        //     is within convergence tolerance of the seek target, then
        //     apply and release the pin. This is what prevents the
        //     snap-back the user reported: with Spotify-via-AppleScript
        //     the stream takes a beat to reflect the new position, and a
        //     fixed-duration tail isn't long enough — convergence-based
        //     release waits exactly as long as the round-trip needs.
        //  3. Otherwise — apply normally.
        if state.isScrubbing {
            // No-op; the view-local dragSeconds is authoritative.
        } else if let pin = state.seekPin {
            if let elapsed = payload.elapsedTime {
                let delta = abs(elapsed - pin.target)
                if delta <= NowPlayingState.seekConvergenceToleranceSeconds {
                    NSLog("[MediaControls] seek pin converged target=\(pin.target) elapsed=\(elapsed) Δ=\(String(format: "%.2f", delta))s waited=\(String(format: "%.2f", Date().timeIntervalSince(pin.startedAt)))s")
                    state.elapsed = elapsed
                    if let ts = payload.timestamp, let date = Self.iso8601.date(from: ts) {
                        state.lastElapsedUpdate = date
                    } else {
                        state.lastElapsedUpdate = Date()
                    }
                    state.clearSeekPin()
                }
                // else: pre-seek straggler — drop, keep waiting for the
                // player to actually report the new position.
            }
        } else {
            if let elapsed = payload.elapsedTime {
                // Pause-time stale-snapshot guard: while paused, audio
                // isn't moving — so any adapter elapsed that's *behind*
                // our current state.elapsed is by definition a stale
                // snapshot (the willSet projection in NowPlayingState
                // wrote the correct paused position when the pause
                // flag flipped; Spotify's MediaRemote pause payload
                // routinely carries a snapshot taken hundreds of ms
                // earlier). Forward updates while paused are still
                // applied — those represent a real manual seek the
                // user did with the player UI.
                let isPausedBackwardSnapshot = !state.isPlaying
                    && elapsed < state.elapsed
                if !isPausedBackwardSnapshot {
                    state.elapsed = elapsed
                    if let ts = payload.timestamp, let date = Self.iso8601.date(from: ts) {
                        state.lastElapsedUpdate = date
                    } else {
                        state.lastElapsedUpdate = Date()
                    }
                }
            } else if !isValid {
                state.elapsed = 0
                state.lastElapsedUpdate = .distantPast
            }
        }

        if let artworkB64 = payload.artworkData {
            let cleaned = artworkB64.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: cleaned), let image = NSImage(data: data) {
                // Dedup at the source: re-emits of the same bytes are
                // common (the adapter's own "artwork briefly
                // disappeared, re-emit" recovery, plus MediaRemote's
                // own stream redundancy). Skipping the write here
                // prevents downstream observers — most expensively the
                // backdrop blur service — from recomputing on data
                // they've already seen.
                if state.artworkData != data {
                    state.artworkData = data
                    state.artwork = image
                }
            }
        } else if !isValid {
            state.artworkData = nil
            state.artwork = nil
        }
        // Otherwise: artwork is missing from this payload but media is still
        // valid — keep the existing artwork. The adapter has a built-in fix
        // that re-emits artwork when it briefly disappears mid-track.
    }

    // MARK: - Process termination

    private func handleProcessTerminated(exitStatus: Int32) {
        streamProcess = nil

        // Non-zero exit usually means: missing entitlement (adapter broken on
        // this OS) or bad arguments. Don't loop — flip to unavailable.
        if exitStatus != 0 {
            consecutiveStartFailures += 1
            if consecutiveStartFailures >= Self.maxRestartAttempts {
                state.adapterAvailable = false
                return
            }
        }

        // Restart after a short delay so we don't busy-loop if the adapter
        // exits immediately for some reason.
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    // MARK: - Bundle paths

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var scriptPath: String? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")?.path
    }

    private static var frameworkPath: String? {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        return frameworks + "/MediaRemoteAdapter.framework"
    }

    static var testClientPath: String? {
        Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path
    }

    /// Optional one-shot self-test. Returns true if the adapter can talk to
    /// MediaRemote on this system. Not called automatically because the test
    /// can briefly inject a fake media entry — keep this for a future
    /// "Diagnose…" affordance in settings.
    static func runSelfTest() async -> Bool {
        guard let script = scriptPath, let framework = frameworkPath, let helper = testClientPath else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, framework, helper, "test"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - JSON shapes

    private struct StreamUpdate: Decodable {
        let type: String
        let diff: Bool?
        let payload: StreamPayload
    }

    private struct StreamPayload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let timestamp: String?
        let playbackRate: Double?
        let playing: Bool?
        let parentApplicationBundleIdentifier: String?
        let bundleIdentifier: String?
        let artworkData: String?
        let artworkMimeType: String?
    }
}
