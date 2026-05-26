import AppKit
import SwiftUI

/// Live activity for active music playback. Two visual modes driven by
/// `showsLyrics`: default = artwork + animated equalizer flanking the
/// camera; lyrics = artwork + scrolling lyrics column. Tapping the
/// artwork (handled inside the view) toggles between the two; the
/// bridge rebuilds the activity with the new size when the toggle
/// flips so the pill animates to its new dimensions.
struct NowPlayingActivity: NotchActivity {
    let id: String = "activity.nowplaying"
    var priority: Int { NotchActivityPriority.nowPlaying }

    let snapshot: Snapshot
    /// When true, replaces the equalizer with the scrolling lyrics
    /// view AND grows the pill (wider trailing wing + taller) to fit.
    /// Driven by `NotchLyricsToggleState.shared.enabled`.
    let showsLyrics: Bool

    struct Snapshot: Equatable {
        let title: String
        let artist: String
        let artwork: NSImage?
    }

    /// Inner margin — the gap between the artwork (or any wing
    /// content) and the camera dead-zone. Also used as the vertical
    /// top/bottom slack around the artwork. Keep small: the inward
    /// top-corner curve of the pill is `baseHeight/3 - 4 ≈ 6.7pt`, so
    /// content this close to the camera still clears the curve.
    static let innerMargin: CGFloat = 4
    /// Outer margin — gap from the pill's outer left/right border to
    /// the artwork. Bigger than inner so the outer vertical edge of
    /// the pill doesn't read as cramped against the artwork (the
    /// previous symmetric 4pt was too tight — the inward top-corner
    /// curve made the outer border feel even closer than it
    /// numerically was).
    static let outerMargin: CGFloat = 12
    /// Trailing wing width in lyrics mode — wide enough that typical
    /// lyric lines (25-35 chars at 14pt rounded) fit without
    /// truncation; tail-truncates on outliers.
    private static let lyricsWingWidth: CGFloat = 260
    /// Default pill height — flush with the physical notch.
    /// Lyrics mode grows past this so the scroller has vertical room
    /// for past + current + upcoming lines.
    private static let lyricsModeHeight: CGFloat = 64

    /// Dynamic layout driven by the pill's actual height `H`.
    /// - Artwork size = `H - 2·innerMargin` (square, fills the pill
    ///   vertically minus the uniform inner margin top/bottom).
    /// - Artwork wing width = `artwork + innerMargin + outerMargin`
    ///   — inner gap (camera-side) is smaller, outer gap (border-
    ///   side) is bigger, so the outer pill border has visible
    ///   breathing room.
    /// - Equalizer wing mirrors the artwork wing.
    ///
    /// pillH 32 → artwork 24, wing 24+4+12 = 40pt
    /// pillH 64 → artwork 56, wing 56+4+12 = 72pt
    static func artworkSize(forPillHeight height: CGFloat) -> CGFloat {
        max(0, height - innerMargin * 2)
    }

    static func artworkWingWidth(forPillHeight height: CGFloat) -> CGFloat {
        artworkSize(forPillHeight: height) + innerMargin + outerMargin
    }

    func size(base: CGSize) -> CGSize {
        let height = showsLyrics ? Self.lyricsModeHeight : base.height
        let artworkWing = Self.artworkWingWidth(forPillHeight: height)
        let trailingWing = showsLyrics ? Self.lyricsWingWidth : artworkWing

        return CGSize(
            width: base.width + artworkWing + trailingWing,
            height: height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        // Activity view is sized to whatever the engine reports for
        // `size(base:)`, but the view needs to know the same pill
        // height up-front to compute artwork dimensions. Passing it
        // through (instead of using GeometryReader) keeps the layout
        // deterministic and avoids the extra layout pass GeometryReader
        // would introduce inside the spring animation.
        AnyView(NowPlayingActivityView(
            snapshot: snapshot,
            showsLyrics: showsLyrics,
            pillHeight: showsLyrics ? Self.lyricsModeHeight : 32,
            lyricsWingWidth: Self.lyricsWingWidth,
            innerMargin: Self.innerMargin,
            outerMargin: Self.outerMargin
        ))
    }
}

private struct NowPlayingActivityView: View {
    @Environment(\.physicalNotchWidth) private var physicalNotchWidth
    @ObservedObject private var toggle = NotchLyricsToggleState.shared
    @ObservedObject private var nowPlaying = MediaControls.shared.state
    @ObservedObject private var lyricsService = MediaControls.shared.lyrics
    let snapshot: NowPlayingActivity.Snapshot
    let showsLyrics: Bool
    /// Current pill height, passed from the activity. Drives the
    /// dynamic artwork sizing math.
    let pillHeight: CGFloat
    let lyricsWingWidth: CGFloat
    /// Camera-side margin (small). Used vertically for top/bottom
    /// slack and horizontally for the camera-facing gap.
    let innerMargin: CGFloat
    /// Pill-border-side margin (bigger). Used horizontally only — gives
    /// the outer pill edge visible breathing room from the content.
    let outerMargin: CGFloat

    private var artworkSize: CGFloat {
        NowPlayingActivity.artworkSize(forPillHeight: pillHeight)
    }

    private var artworkWingWidth: CGFloat {
        NowPlayingActivity.artworkWingWidth(forPillHeight: pillHeight)
    }

    private var equalizerWingWidth: CGFloat {
        // Mirror the artwork wing so the two sides frame the camera
        // identically in default (no-lyrics) mode.
        artworkWingWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            // Leading wing — artwork right-aligned, snug against the
            // camera cutout. This is the ONLY hit-testable region in
            // the pill: tap toggles lyrics mode.
            artworkTapTarget
                .frame(width: artworkWingWidth, alignment: .trailing)

            // Camera dead-zone — exact notch width, transparent, no
            // hit-testing so clicks fall through to whatever's behind.
            Color.clear
                .frame(width: physicalNotchWidth)
                .allowsHitTesting(false)

            // Trailing wing — equalizer or lyrics scroller depending
            // on toggle. Also non-interactive (only the artwork is a
            // tap target).
            trailingContent
                .allowsHitTesting(false)
        }
        .frame(maxHeight: .infinity)
    }

    /// Artwork sized vertically to fill the pill height minus inner
    /// margins top and bottom. Horizontally positioned with the bigger
    /// `outerMargin` on the LEFT (outer pill edge) and the smaller
    /// `innerMargin` on the RIGHT (camera side), so the outer edge of
    /// the pill has visible breathing room.
    ///
    ///   pill 32 → artwork 24, wing 40 (outer 12, artwork 24, inner 4)
    ///   pill 64 → artwork 56, wing 72 (outer 12, artwork 56, inner 4)
    ///
    /// Tap gesture attaches at the wing rect so the click target grows
    /// with the artwork — much easier to hit in lyrics mode.
    private var artworkTapTarget: some View {
        let size = artworkSize
        return artwork
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .padding(.leading, outerMargin)
            .padding(.trailing, innerMargin)
            .frame(width: artworkWingWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                toggle.enabled.toggle()
            }
    }

    /// Trailing-side content. Mirror image of `artworkTapTarget`:
    /// content sits with `innerMargin` on the LEFT (camera side) and
    /// `outerMargin` on the RIGHT (outer pill edge). Equalizer wing
    /// uses the same width as the artwork wing so the activity frames
    /// the camera symmetrically.
    @ViewBuilder
    private var trailingContent: some View {
        if showsLyrics, let lyrics = lyricsService.lyrics {
            LyricsScrollingView(
                lyrics: lyrics,
                elapsedTimeProvider: { nowPlaying.projectedElapsed },
                style: .compact
            )
            .padding(.leading, innerMargin)
            .padding(.trailing, outerMargin)
            .frame(width: lyricsWingWidth, alignment: .trailing)
        } else if showsLyrics {
            // Lyrics toggled on but not loaded yet (loading / notFound).
            // Fall back to the equalizer so the activity doesn't go
            // blank; the trailing wing stays at lyricsWingWidth so the
            // artwork doesn't visually jump when lyrics eventually
            // load.
            EqualizerBars()
                .frame(width: 18, height: 14)
                .padding(.leading, innerMargin)
                .padding(.trailing, outerMargin)
                .frame(width: lyricsWingWidth, alignment: .trailing)
        } else {
            EqualizerBars()
                .frame(width: 18, height: 14)
                .padding(.leading, innerMargin)
                .padding(.trailing, outerMargin)
                .frame(width: equalizerWingWidth, alignment: .trailing)
        }
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
