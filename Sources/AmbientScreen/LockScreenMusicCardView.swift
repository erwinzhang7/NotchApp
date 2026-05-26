import AppKit
import SwiftUI

/// Bridge from NSVisualEffectView into SwiftUI for the glass background.
/// Applies the rounded-corner mask at the CALayer level. SwiftUI's
/// `.clipShape` does not clip AppKit-backed `NSViewRepresentable` content
/// — it leaves a square rectangle visible behind the SwiftUI rounded
/// shape, which read as a second outer layer.
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = false
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Compact music card used for the lock-screen widget. Display + standard
/// transport: previous / play-pause / next + draggable scrubber. On the
/// actual lock screen the password sheet takes keyboard focus, but mouse
/// events still reach our panel through the SkyLight space.
struct LockScreenMusicCardView: View {
    @ObservedObject var state: NowPlayingState
    let adapter: MediaRemoteAdapter

    /// Position the user is currently dragging the scrubber to.
    @State private var dragSeconds: Double?

    private let artworkSize: CGFloat = 220

    var body: some View {
        VStack(spacing: 18) {
            artwork
                .frame(width: artworkSize, height: artworkSize)

            VStack(spacing: 3) {
                Text(state.hasMedia ? state.title : "Nothing playing")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                Text(secondary)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }

            if state.hasMedia {
                progressBar
                    .frame(width: artworkSize)
                transportRow
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBlur(
                material: .hudWindow,
                blendingMode: .behindWindow,
                cornerRadius: 24
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        // No SwiftUI .shadow here — the NSPanel casts a system shadow
        // shaped to the layer-rounded hosting view (see
        // LockScreenMusicWidgetController.makePanel).
        .preferredColorScheme(.dark)
    }

    private var secondary: String {
        if !state.hasMedia { return " " }
        return state.artist.isEmpty ? state.album : state.artist
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = state.artwork {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                )
        }
    }

    // MARK: - Scrubber (mirrors NowPlayingView's interactive bar)

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.duration, 0)
            let elapsed = displayedElapsed
            let progress: Double = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 3)
                            .frame(maxHeight: .infinity)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                            .frame(maxHeight: .infinity)
                    }
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
        HStack(spacing: 28) {
            transportButton(systemName: "backward.fill", size: 14) {
                adapter.previousTrack()
            }
            transportButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                size: 20
            ) {
                adapter.togglePlayPause()
            }
            transportButton(systemName: "forward.fill", size: 14) {
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
                .frame(width: size + 18, height: size + 12)
                .contentShape(Rectangle())
                // Smooth icon morph for the play/pause swap.
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
