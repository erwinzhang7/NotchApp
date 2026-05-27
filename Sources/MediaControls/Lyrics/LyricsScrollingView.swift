import SwiftUI

/// Apple-Music-style synced-lyrics view. Inspired by DynamicNotch's
/// `LockScreenLyricsView`: instead of a ScrollView + scrollTo (which
/// has a jittery feel because the scroll has to settle each time), the
/// view shows a fixed window of N lines centered on the active one and
/// asymmetric move-edge transitions slide new lines in at the bottom
/// and old lines out at the top. Per-line styling (opacity, scale,
/// blur) is derived from each line's distance from active so the
/// surrounding lines visibly recede from the focal one.
///
/// Plain-text (unsynced) lyrics render as a static list with nothing
/// highlighted — without timestamps there's no "active" line to chase.
///
/// Tappable: with `onLineTap` provided, each synced line becomes a
/// tap target that fires the callback with the line. Used by the
/// expanded shell to jump-seek the player when the user clicks a line.
struct LyricsScrollingView: View {
    let lyrics: TrackLyrics
    let elapsedTimeProvider: () -> TimeInterval
    let style: Style
    var onLineTap: ((LyricLine) -> Void)? = nil
    /// Color for the lyric text. Defaults to white — caller can pass
    /// `.black` when the background is so bright that white reads
    /// poorly. Active vs inactive opacity is applied on top of this.
    var textColor: Color = .white

    enum Style {
        /// Lock-screen right column — fits 5-7 lines.
        case tall
        /// Expanded shell's now-playing pane — 160pt vertical, ~3-5
        /// lines visible, fonts sized to read without dwarfing the
        /// 90pt artwork beside it.
        case shell
        /// Notch — fits 2-3 lines under the inward shape.
        case compact

        /// How many lines on each side of the active one stay visible.
        /// Total visible = 2·radius + 1 (active itself + N above + N below).
        /// Lock-screen (.tall) goes wider — the column has ~490pt of
        /// vertical room and opacity falloff already dims the edges
        /// enough that the old "ghost text border" complaint no longer
        /// surfaces (the per-line blur that caused it has been removed).
        var windowRadius: Int {
            switch self {
            case .tall:    return 4
            case .shell:   return 2
            case .compact: return 1
            }
        }

        var activeFontSize: CGFloat {
            switch self {
            case .tall:    return 31
            case .shell:   return 16
            case .compact: return 13
            }
        }

        var inactiveFontSize: CGFloat {
            switch self {
            case .tall:    return 25
            case .shell:   return 13
            case .compact: return 11
            }
        }

        var lineSpacing: CGFloat {
            switch self {
            case .tall:    return 20
            case .shell:   return 6
            case .compact: return 3
            }
        }

        var fadeHeight: CGFloat {
            // Soft fade at top and bottom so off-center lines don't
            // pop. Sized to the container's vertical room.
            switch self {
            case .tall:    return 60
            case .shell:   return 24
            case .compact: return 10
            }
        }
    }

    var body: some View {
        // 10Hz active-line polling — faster than DynamicNotch's 0.35s
        // (lock-screen lyrics there feel laggy on dense songs). Cheap;
        // the recomputation is just an array bisection on elapsedTime.
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let elapsed = elapsedTimeProvider()
            content(elapsed: elapsed)
        }
    }

    @ViewBuilder
    private func content(elapsed: TimeInterval) -> some View {
        if lyrics.lines.isEmpty {
            EmptyView()
        } else if lyrics.isSynced {
            let activeIndex = lyrics.activeLineIndex(at: elapsed) ?? 0
            slidingWindow(activeIndex: activeIndex)
        } else {
            plainStaticList
        }
    }

    /// Sliding-window view for synced lyrics. As `activeIndex`
    /// advances, the `ForEach` set changes (new id at the bottom, old
    /// id at the top) and asymmetric transitions handle the slide.
    /// The container's `.animation(value: activeIndex)` ties every
    /// per-line scale/opacity/blur change to the same spring so the
    /// whole block moves as a coherent unit.
    private func slidingWindow(activeIndex: Int) -> some View {
        let visible = visibleLines(around: activeIndex)

        return VStack(alignment: .leading, spacing: style.lineSpacing) {
            ForEach(visible) { line in
                LyricLineView(
                    line: line,
                    distanceFromActive: line.id - activeIndex,
                    style: style,
                    textColor: textColor,
                    onTap: onLineTap.map { handler in { handler(line) } }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // No padding / no fade mask — the user asked for "just lyrics",
        // no border or frame around the column. Lines extend to the
        // outer edges of whatever frame the parent supplies.
        // Single spring on the activeIndex value drives every
        // animatable change at once — slide-in, slide-out, scale,
        // opacity, blur, font-size. Slightly heavier damping (0.88)
        // than the scroll-spring was using (0.85) so the lines settle
        // crisply instead of overshooting visibly.
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: activeIndex)
    }

    private var plainStaticList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(
                            size: style.inactiveFontSize,
                            weight: .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(textColor.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func visibleLines(around active: Int) -> [LyricLine] {
        guard !lyrics.lines.isEmpty else { return [] }
        let lower = max(0, active - style.windowRadius)
        let upper = min(lyrics.lines.count - 1, active + style.windowRadius)
        return Array(lyrics.lines[lower...upper])
    }
}

/// Single line. All animatable properties (opacity / scale / blur /
/// font size) derive from `distanceFromActive` so the parent spring
/// animates every change to those values together when the active
/// line shifts.
private struct LyricLineView: View {
    let line: LyricLine
    let distanceFromActive: Int
    let style: LyricsScrollingView.Style
    let textColor: Color
    let onTap: (() -> Void)?

    private var isActive: Bool { distanceFromActive == 0 }
    private var clampedDistance: CGFloat {
        min(CGFloat(abs(distanceFromActive)), 4)
    }

    private var opacity: Double {
        isActive ? 1.0 : max(0.14, 0.45 - Double(clampedDistance) * 0.10)
    }

    private var scale: CGFloat {
        max(0.78, 1 - clampedDistance * 0.07)
    }

    var body: some View {
        let label = Text(line.text)
            .font(.system(
                size: isActive ? style.activeFontSize : style.inactiveFontSize,
                weight: isActive ? .bold : .medium,
                design: .rounded
            ))
            .foregroundStyle(textColor.opacity(opacity))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .scaleEffect(scale, anchor: .leading)
            // No blur on dimmed lines — accumulated blur at the edges
            // of the visible window produced a ghost-text smudge that
            // read as a soft border around the column. Opacity +
            // scale alone give enough perspective falloff.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

        Group {
            if line.startTime != nil, let onTap {
                label.onTapGesture(perform: onTap)
            } else {
                label
            }
        }
    }
}
