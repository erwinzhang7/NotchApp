import SwiftUI

/// Now-playing UI mounted in the Ambient tab. Two states: a playing layout
/// (artwork left, title/artist/transport/scrubber right) and a "nothing
/// playing" / "media access unavailable" idle layout.
struct NowPlayingView: View {
    @ObservedObject var state: NowPlayingState
    let adapter: MediaRemoteAdapter

    /// Position the user is currently dragging the scrubber to, in seconds.
    /// Nil when no drag in progress — display falls back to projectedElapsed.
    @State private var dragSeconds: Double?

    var body: some View {
        Group {
            if state.hasMedia {
                playing
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    // MARK: - Playing layout

    private var playing: some View {
        // alignment: .center keeps the right-side stack vertically
        // centered against the album art so the whole block reads as
        // ~one art-height tall instead of spreading to fill all the
        // section's vertical space. Spacers removed and per-element
        // .padding(.top, …) values chosen so the stack height lands
        // close to the 90pt art height (≈ title 16 + artist 16 + bar 36
        // + transport 26 = ~94pt total).
        HStack(alignment: .center, spacing: 12) {
            artwork
                .frame(width: 90, height: 90)

            VStack(alignment: .leading, spacing: 0) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(state.artist.isEmpty ? state.album : state.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)

                progressBar
                    .padding(.top, 6)

                transportRow
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = state.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                )
        }
    }

    /// Live progress bar that doubles as a scrubber. While the user drags,
    /// the thumb follows the cursor and incoming stream updates for elapsed
    /// time are suppressed (via state.isScrubbing) so the drag isn't fought.
    /// On release, a `seek` command is sent through the adapter and the
    /// suppression is released after a short tail so the post-seek stream
    /// update can land cleanly.
    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.duration, 0)
            let elapsed = displayedElapsed
            let progress: Double = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0

            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)
                            .frame(maxHeight: .infinity)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                            .frame(maxHeight: .infinity)
                    }
                    // Hit target is taller than the visible capsule so the
                    // bar is comfortable to grab — 3pt visual, 14pt hit area.
                    // For sources that can't seek (proven by a prior failed
                    // attempt) the gesture is disabled so the bar is
                    // display-only — no false draggable affordance.
                    .contentShape(Rectangle())
                    .gesture(
                        scrubGesture(width: geo.size.width, duration: duration),
                        including: state.canSeekCurrentSource ? .gesture : .none
                    )
                }
                .frame(height: 14)

                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text(format(duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// What to display in the bar.
    ///  - Active drag: the cursor position the user is dragging to.
    ///  - Post-release seek pin: the target the user dropped at, held
    ///    there until the stream reports a converged elapsed value.
    ///  - Otherwise: the live projection from the adapter stream.
    private var displayedElapsed: Double {
        if let drag = dragSeconds { return drag }
        if let pin = state.seekPin { return pin.target }
        return state.projectedElapsed
    }

    private func scrubGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                let clampedX = max(0, min(width, value.location.x))
                let seconds = (clampedX / width) * duration
                if dragSeconds == nil {
                    state.isScrubbing = true
                    // A new drag supersedes any pin still waiting on a
                    // previous release's convergence.
                    state.clearSeekPin()
                }
                dragSeconds = seconds
            }
            .onEnded { _ in
                guard let seconds = dragSeconds else { return }
                let bundleId = state.bundleIdentifier
                dragSeconds = nil
                // Pin first so the very next render sees pin.target rather
                // than briefly falling through to projectedElapsed (which
                // is the frozen pre-seek position). isScrubbing flips off
                // here too — suppression of stream updates now comes from
                // the pin's convergence check instead of a fixed timer.
                state.setSeekPin(target: seconds, bundleId: bundleId)
                state.isScrubbing = false
                adapter.seek(toSeconds: seconds)
            }
    }

    private var transportRow: some View {
        HStack(spacing: 22) {
            transportButton(systemName: "backward.fill", size: 12) {
                adapter.previousTrack()
            }
            transportButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                size: 16
            ) {
                adapter.togglePlayPause()
            }
            transportButton(systemName: "forward.fill", size: 12) {
                adapter.nextTrack()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Idle layout

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: state.adapterAvailable ? "music.quarternote.3" : "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(state.adapterAvailable ? "Nothing playing" : "Media access unavailable")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
