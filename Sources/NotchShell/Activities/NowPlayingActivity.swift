import AppKit
import SwiftUI

/// Live activity for active music playback. Inspired by DynamicNotch's
/// now-playing live activity but compact-only — artwork on the left of
/// the physical notch, animated equalizer bars on the right, no
/// expand-on-tap, no scrubber.
struct NowPlayingActivity: NotchActivity {
    let id: String = "activity.nowplaying"
    var priority: Int { NotchActivityPriority.nowPlaying }

    let snapshot: Snapshot

    struct Snapshot: Equatable {
        let title: String
        let artist: String
        let artwork: NSImage?
    }

    /// Symmetric wings — music is the one activity where left/right
    /// symmetry actually matters visually (artwork ↔ equalizer flank
    /// the camera like a stereo pair). 50pt per wing gives the 22pt
    /// artwork + 8pt cam-side padding ~20pt of slack and the inward
    /// curve doesn't bite the artwork.
    private static let wingWidth: CGFloat = 50

    func size(base: CGSize) -> CGSize {
        CGSize(width: base.width + Self.wingWidth * 2, height: base.height)
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(NowPlayingActivityView(snapshot: snapshot, wingWidth: Self.wingWidth))
    }
}

private struct NowPlayingActivityView: View {
    @Environment(\.physicalNotchWidth) private var physicalNotchWidth
    let snapshot: NowPlayingActivity.Snapshot
    let wingWidth: CGFloat

    private let cameraSidePadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            // Leading wing — artwork right-aligned, snug against the
            // camera cutout.
            artwork
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.trailing, cameraSidePadding)
                .frame(width: wingWidth, alignment: .trailing)

            // Camera dead-zone — exact notch width, transparent.
            Color.clear
                .frame(width: physicalNotchWidth)

            // Trailing wing — equalizer left-aligned, snug against the
            // camera cutout. Symmetric counterweight to the artwork.
            EqualizerBars()
                .frame(width: 18, height: 14)
                .padding(.leading, cameraSidePadding)
                .frame(width: wingWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        if let nsImage = snapshot.artwork {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                )
        }
    }
}

/// Three-bar equalizer that bounces in place. Pure SwiftUI, no
/// timer-driven state — uses a `TimelineView` so the animation runs
/// from the system frame clock without us polling.
private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                bar(height: heightForBar(0, t: t))
                bar(height: heightForBar(1, t: t))
                bar(height: heightForBar(2, t: t))
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white)
            .frame(width: 3, height: height)
    }

    /// Per-bar sine wave with a phase offset so the three don't move in
    /// lockstep. Range 4..14pt.
    private func heightForBar(_ index: Int, t: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.7
        let value = (sin(t * 4 + phase) + 1) / 2     // 0...1
        return 4 + CGFloat(value) * 10
    }
}
