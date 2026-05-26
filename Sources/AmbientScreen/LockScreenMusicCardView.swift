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

/// Two-state music card for the lock screen.
///
/// - **Compact (default)**: artwork on the left, title/artist/scrubber/
///   transport stacked to the right. iPad-Music-style.
/// - **Lifted**: clicking the artwork lifts it above the card as a big
///   square; the card reflows to info-only. matchedGeometryEffect
///   transitions the artwork between the two positions smoothly.
///
/// **Lyrics (lifted state only)**: when the setting is on and synced
/// lyrics are loaded for the current track, a scrolling lyrics column
/// appears to the right of the artwork+card column. Layout switches to
/// HStack; the original column keeps its sizes and positions unchanged.
///
/// Plus: gentle "breathing" pulse on the artwork while playing, and an
/// accent color extracted from the artwork that tints the scrubber.
struct LockScreenMusicCardView: View {
    @ObservedObject var state: NowPlayingState
    /// Shared with the backdrop panel — clicking the artwork flips
    /// `isArtworkLifted` here, the backdrop watches the same flag.
    @ObservedObject var cardState: LockScreenMusicCardState
    @ObservedObject var lyricsService: LyricsService
    @ObservedObject var ambient: AmbientSettings
    let adapter: MediaRemoteAdapter

    /// Drives the slow autoreversing scale that gives a playing track a
    /// subtle "alive" feel.
    @State private var pulse = false
    /// Position the user is currently dragging the scrubber to.
    @State private var dragSeconds: Double?

    /// Shared id so SwiftUI animates the same artwork view across the
    /// two layouts rather than crossfading two separate views.
    @Namespace private var artworkNamespace

    private let smallArtworkSize: CGFloat = 64
    private let bigArtworkSize: CGFloat = 320
    /// Width of the left column (artwork + card) when lyrics column is
    /// showing — pinned so the artwork keeps its 320pt footprint and
    /// the card matches.
    private let leftColumnWidth: CGFloat = 320
    /// Width of the lyrics column. Same as the artwork so the two read
    /// as a balanced pair.
    private let lyricsColumnWidth: CGFloat = 320
    private let cardPadding: CGFloat = 16
    /// Tall enough to fit the big (lifted) layout — 320pt artwork +
    /// 14pt spacing + the card (title/artist/scrubber/transport,
    /// ~150pt). Both the small and big columns are bottom-aligned
    /// inside this fixed-height frame so their **bottoms land at the
    /// same Y** regardless of state — visual continuity when toggling
    /// lift on/off.
    private let leftColumnFrameHeight: CGFloat = 490

    private var accent: Color { ArtworkColor.accent(for: state.artwork) }

    /// Lyrics column is shown when the setting is on, the artwork is
    /// lifted, and we actually have lyrics loaded. Empty `notFound` /
    /// loading / failed states collapse back to the current no-lyrics
    /// layout per the design — no placeholder column.
    private var showsLyricsColumn: Bool {
        ambient.showLockScreenLyrics &&
        cardState.isArtworkLifted &&
        lyricsService.lyrics != nil
    }

    var body: some View {
        // Three lock-screen states drive three different positions:
        //
        //   small (compact)         → card dead-center on the screen
        //   big (lifted, no lyrics) → art + card dead-center
        //   big + lyrics            → art + card centered on the 25%
        //                              mark; lyrics left-aligned
        //                              starting at midpoint + 20pt
        //
        // GeometryReader provides the panel width (= main display
        // width since the controller sizes the panel to the full
        // screen). Columns use absolute positioning via .position().
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                leftColumn
                    // Bottom-aligned inside the fixed-height frame so
                    // the column's bottom edge lands at the same Y
                    // whether we're showing just the small card or
                    // the full artwork + card stack.
                    .frame(
                        width: leftColumnWidth,
                        height: leftColumnFrameHeight,
                        alignment: .bottom
                    )
                    .position(
                        x: leftColumnCenterX(in: geo.size.width),
                        y: geo.size.height / 2
                    )

                if showsLyricsColumn {
                    let lyricsLeading = geo.size.width * 0.5 + 20
                    let lyricsWidth = max(0, geo.size.width - lyricsLeading - 16)
                    lyricsColumn
                        // Match the left column's frame height so the
                        // lyrics scroller occupies the same vertical
                        // band as the artwork + card.
                        .frame(
                            width: lyricsWidth,
                            height: leftColumnFrameHeight,
                            alignment: .leading
                        )
                        .position(
                            x: lyricsLeading + lyricsWidth / 2,
                            y: geo.size.height / 2
                        )
                }
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    /// Horizontal center of the art + card column, in panel-local
    /// coordinates. Centered on screen when there's no lyrics column;
    /// shifted to the 25%-from-left mark when lyrics need room on
    /// the right.
    private func leftColumnCenterX(in panelWidth: CGFloat) -> CGFloat {
        showsLyricsColumn ? panelWidth * 0.25 : panelWidth * 0.5
    }

    // MARK: - Layouts

    /// Artwork + card column. In compact mode it's just the card; in
    /// lifted modes the big artwork sits above the card. Positioned
    /// at the 25%-from-left mark in `body` regardless of mode.
    @ViewBuilder
    private var leftColumn: some View {
        if cardState.isArtworkLifted {
            VStack(spacing: 14) {
                liftedArtwork
                card
            }
        } else {
            card
        }
    }

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = lyricsService.lyrics {
            LyricsScrollingView(
                lyrics: lyrics,
                elapsedTimeProvider: { state.projectedElapsed },
                style: .tall,
                textColor: lyricsTextColor
            )
        }
    }

    /// White by default. Drops to black only when the artwork's
    /// dominant tone is extremely bright (HSB brightness > 0.90) —
    /// the rare case where the backdrop's dark overlay can't drop
    /// the underlying lit pixels enough for white text to read.
    /// Sampled from the artwork palette (CIAreaAverage of the
    /// current artwork bytes).
    private var lyricsTextColor: Color {
        guard let data = state.artworkData else { return .white }
        let palette = NowPlayingArtworkPaletteExtractor.extract(from: data)
        guard let resolved = palette.equalizerBaseColor.usingColorSpace(.sRGB) else {
            return .white
        }
        var brightness: CGFloat = 0
        resolved.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return brightness > 0.90 ? .black : .white
    }

    // MARK: - Lifted artwork (state 2)

    private var liftedArtwork: some View {
        artwork(size: bigArtworkSize)
            .matchedGeometryEffect(id: "art", in: artworkNamespace)
            .onTapGesture { toggleLift() }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: - Card

    private var card: some View {
        cardContent
            .padding(cardPadding)
            .frame(maxWidth: .infinity)
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
    }

    @ViewBuilder
    private var cardContent: some View {
        if cardState.isArtworkLifted {
            // Lifted: info column only, no embedded art, centered.
            infoColumn(centered: true)
        } else {
            // Compact: top row is art + title/artist side-by-side;
            // scrubber and transport span the full card width below.
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    artwork(size: smallArtworkSize)
                        .matchedGeometryEffect(id: "art", in: artworkNamespace)
                        .onTapGesture { toggleLift() }
                    titleArtistColumn(centered: false)
                }
                if state.hasMedia {
                    progressBar
                    transportRow(centered: true)
                }
            }
        }
    }

    @ViewBuilder
    private func titleArtistColumn(centered: Bool) -> some View {
        let alignment: HorizontalAlignment = centered ? .center : .leading
        VStack(alignment: alignment, spacing: 2) {
            Text(state.hasMedia ? state.title : "Nothing playing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(centered ? .center : .leading)
            Text(secondary)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .multilineTextAlignment(centered ? .center : .leading)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// Used by the lifted (art-floats-above) state: title + artist +
    /// scrubber + transport all stacked in one centered column.
    @ViewBuilder
    private func infoColumn(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            titleArtistColumn(centered: centered)
            if state.hasMedia {
                progressBar
                transportRow(centered: centered)
            }
        }
    }

    private var secondary: String {
        if !state.hasMedia { return " " }
        return state.artist.isEmpty ? state.album : state.artist
    }

    // MARK: - Artwork (parametric)

    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let img = state.artwork {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.36, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    )
                    .frame(width: size, height: size)
            }
        }
        // Gentle "breathing" while playing; pauses at 1.0 when stopped.
        .scaleEffect(state.isPlaying && pulse ? 1.02 : 1.0)
        .onAppear { startPulseIfPlaying() }
        .onChange(of: state.isPlaying) { _, _ in startPulseIfPlaying() }
    }

    private func startPulseIfPlaying() {
        if state.isPlaying {
            withAnimation(
                .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.4)) {
                pulse = false
            }
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
                            .fill(accent)
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

    private func transportRow(centered: Bool) -> some View {
        HStack(spacing: 24) {
            transportButton(systemName: "backward.fill", size: 13) {
                adapter.previousTrack()
            }
            transportButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                size: 18
            ) {
                adapter.togglePlayPause()
            }
            transportButton(systemName: "forward.fill", size: 13) {
                adapter.nextTrack()
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
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
                .frame(width: size + 16, height: size + 10)
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

    // MARK: - Interaction

    private func toggleLift() {
        let start = Date()
        NSLog("[Toggle] lock-card.toggleLift START isLifted=%@->%@",
              cardState.isArtworkLifted ? "Y" : "N",
              cardState.isArtworkLifted ? "N" : "Y")
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            cardState.isArtworkLifted.toggle()
        }
        NSLog("[Toggle] lock-card.toggleLift END elapsed=%.3fs", Date().timeIntervalSince(start))
    }
}
