import SwiftUI

/// Apple-Music-style synced-lyrics view. Active line is bigger, white,
/// vertically centered in the container; surrounding lines are dimmed
/// and scroll past as time advances. Same component, two sizes — tall
/// for the lock-screen lifted-artwork column, compact for the notch.
///
/// Plain-text (unsynced) lyrics render as a static list with nothing
/// highlighted — without timestamps there's no "active" line to chase.
///
/// Caller must drive elapsed time via `elapsedTimeProvider` (typically a
/// closure that reads `NowPlayingState.projectedElapsed`). The view
/// wraps a `TimelineView` so the active line updates frame-to-frame
/// without the caller needing to publish.
struct LyricsScrollingView: View {
    let lyrics: TrackLyrics
    let elapsedTimeProvider: () -> TimeInterval
    let style: Style

    enum Style {
        /// Lock-screen right column — fits 5-7 lines.
        case tall
        /// Notch — fits 2-3 lines under the inward shape.
        case compact

        var activeFontSize: CGFloat {
            switch self {
            case .tall:    return 22
            case .compact: return 14
            }
        }

        var inactiveFontSize: CGFloat {
            switch self {
            case .tall:    return 18
            case .compact: return 12
            }
        }

        var lineSpacing: CGFloat {
            switch self {
            case .tall:    return 14
            case .compact: return 6
            }
        }

        var fadeHeight: CGFloat {
            // Soft fade at top and bottom so off-center lines don't
            // pop. Bigger fade in tall mode where there's more room.
            switch self {
            case .tall:    return 60
            case .compact: return 14
            }
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { ctx in
            let activeIndex = lyrics.activeLineIndex(at: elapsedTimeProvider())
            content(activeIndex: activeIndex)
        }
    }

    @ViewBuilder
    private func content(activeIndex: Int?) -> some View {
        if lyrics.lines.isEmpty {
            // Defensive — TrackLyrics shouldn't ever land here with an
            // empty array, but a malformed LRCLIB response could in
            // theory produce one.
            EmptyView()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: style.lineSpacing) {
                        ForEach(lyrics.lines) { line in
                            lineView(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, style.fadeHeight)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Top + bottom fade so lines off-center dissolve rather
                // than pop against the edge.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: style.fadeHeight / 200),
                            .init(color: .black, location: 1 - style.fadeHeight / 200),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    // Land on the current line without animation so a
                    // mid-song open doesn't scroll from the top.
                    if let index = activeIndex {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, isActive: Bool) -> some View {
        Text(line.text)
            .font(.system(
                size: isActive ? style.activeFontSize : style.inactiveFontSize,
                weight: isActive ? .bold : .medium,
                design: .rounded
            ))
            .foregroundStyle(.white.opacity(isActive ? 1.0 : 0.35))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: isActive)
    }
}
