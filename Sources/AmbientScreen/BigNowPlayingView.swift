import SwiftUI

/// Large iPad-style now-playing card for the ambient screen. Same data
/// source as NowPlayingView (NowPlayingState + MediaRemoteAdapter) but
/// scaled up: large square artwork, big title/artist, full scrubber, and
/// always-visible transport controls.
struct BigNowPlayingView: View {
    @ObservedObject var state: NowPlayingState
    let adapter: MediaRemoteAdapter

    /// Position the user is currently dragging the scrubber to.
    @State private var dragSeconds: Double?

    /// Artwork side length. Sized so the whole card fits comfortably on a
    /// 13" MacBook screen alongside the left sidebar.
    private let artworkSize: CGFloat = 320

    var body: some View {
        VStack(spacing: 24) {
            artwork
                .frame(width: artworkSize, height: artworkSize)

            VStack(spacing: 6) {
                Text(state.hasMedia ? state.title : "Nothing playing")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(secondaryLabel)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .multilineTextAlignment(.center)

            if state.hasMedia {
                progressBar
                    .frame(width: artworkSize)
                transportRow
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var secondaryLabel: String {
        if !state.hasMedia { return state.adapterAvailable ? " " : "Media access unavailable" }
        return state.artist.isEmpty ? state.album : state.artist
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = state.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 80, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
    }

    // MARK: - Scrubber (large variant of NowPlayingView's progressBar)

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.duration, 0)
            let elapsed = displayedElapsed
            let progress: Double = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 4)
                            .frame(maxHeight: .infinity)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * progress), height: 4)
                            .frame(maxHeight: .infinity)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        scrubGesture(width: geo.size.width, duration: duration),
                        including: state.canSeekCurrentSource ? .gesture : .none
                    )
                }
                .frame(height: 18)

                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text(format(duration))
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

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
                    state.clearSeekPin()
                }
                dragSeconds = seconds
            }
            .onEnded { _ in
                guard let seconds = dragSeconds else { return }
                let bundleId = state.bundleIdentifier
                dragSeconds = nil
                state.setSeekPin(target: seconds, bundleId: bundleId)
                state.isScrubbing = false
                adapter.seek(toSeconds: seconds)
            }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 44) {
            transportButton(systemName: "backward.fill", size: 22) {
                adapter.previousTrack()
            }
            transportButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                size: 36
            ) {
                adapter.togglePlayPause()
            }
            transportButton(systemName: "forward.fill", size: 22) {
                adapter.nextTrack()
            }
        }
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
                .frame(width: size + 24, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
