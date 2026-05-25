import AppKit
import SwiftUI

/// Bridge from NSVisualEffectView into SwiftUI for the glass background.
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Compact, display-only music card used for the lock-screen widget. No
/// transport controls — when the Mac is locked Touch ID / password takes
/// keyboard focus and our buttons wouldn't fire reliably anyway.
struct LockScreenMusicCardView: View {
    @ObservedObject var state: NowPlayingState

    private let artworkSize: CGFloat = 220

    var body: some View {
        VStack(spacing: 16) {
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

            if state.hasMedia, state.duration > 0 {
                progressBar
                    .frame(width: artworkSize)
            }
        }
        .padding(24)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
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

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.duration, 0)
            let elapsed = state.projectedElapsed
            let progress: Double = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                    }
                }
                .frame(height: 3)

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

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
