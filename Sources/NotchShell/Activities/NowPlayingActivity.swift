import AppKit
import SwiftUI

/// Live activity for active music playback. Compact-only —
/// artwork on the left, animated equalizer bars on the right.
/// No expand-on-tap, no scrubber, no lyrics toggle here (lyrics are
/// surfaced in the expanded shell's `NowPlayingView`, not the
/// always-visible notch pill).
struct NowPlayingActivity: NotchActivity {
    let id: String = "activity.nowplaying"
    var priority: Int { NotchActivityPriority.nowPlaying }

    let snapshot: Snapshot

    struct Snapshot: Equatable {
        let title: String
        let artist: String
        let artwork: NSImage?
    }

    /// Camera-side margin (small). Used vertically for top/bottom
    /// slack around the artwork and horizontally for the gap to the
    /// camera dead-zone.
    static let innerMargin: CGFloat = 4
    /// Pill-border-side margin (bigger). Used horizontally only — gives
    /// the outer pill edge visible breathing room from the content.
    static let outerMargin: CGFloat = 12

    /// Dynamic layout driven by the pill's actual height `H`.
    /// - Artwork size = `H − 2·innerMargin` (square)
    /// - Artwork wing = `artwork + innerMargin + outerMargin`
    ///
    /// pillH 32 → artwork 24, wing 24+4+12 = 40pt
    static func artworkSize(forPillHeight height: CGFloat) -> CGFloat {
        max(0, height - innerMargin * 2)
    }

    static func artworkWingWidth(forPillHeight height: CGFloat) -> CGFloat {
        artworkSize(forPillHeight: height) + innerMargin + outerMargin
    }

    func size(base: CGSize) -> CGSize {
        let wing = Self.artworkWingWidth(forPillHeight: base.height)
        return CGSize(
            width: base.width + wing * 2,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(NowPlayingActivityView(
            snapshot: snapshot,
            pillHeight: 32,
            innerMargin: Self.innerMargin,
            outerMargin: Self.outerMargin
        ))
    }
}

private struct NowPlayingActivityView: View {
    @Environment(\.physicalNotchWidth) private var physicalNotchWidth
    let snapshot: NowPlayingActivity.Snapshot
    let pillHeight: CGFloat
    let innerMargin: CGFloat
    let outerMargin: CGFloat

    private var artworkSize: CGFloat {
        NowPlayingActivity.artworkSize(forPillHeight: pillHeight)
    }

    private var wingWidth: CGFloat {
        NowPlayingActivity.artworkWingWidth(forPillHeight: pillHeight)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Leading wing — artwork pinned to the outer-left edge with
            // `outerMargin` of breathing room from the pill border and
            // `innerMargin` of gap to the camera dead-zone.
            artwork
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.18, style: .continuous))
                .padding(.leading, outerMargin)
                .padding(.trailing, innerMargin)
                .frame(width: wingWidth, alignment: .leading)

            // Camera dead-zone — exact notch width, transparent, no
            // hit-testing so clicks fall through to whatever's behind.
            Color.clear
                .frame(width: physicalNotchWidth)
                .allowsHitTesting(false)

            // Trailing wing — equalizer mirrored against the outer-right
            // edge with the same inner/outer margin split.
            EqualizerBars()
                .frame(width: 18, height: 14)
                .padding(.leading, innerMargin)
                .padding(.trailing, outerMargin)
                .frame(width: wingWidth, alignment: .trailing)
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
