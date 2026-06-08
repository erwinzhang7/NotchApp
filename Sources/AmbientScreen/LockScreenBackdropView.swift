import AppKit
import SwiftUI

/// Full-screen backdrop that fades in only when the music card's
/// artwork is in its lifted (big) state. Heavy gaussian blur of the
/// album art + a soft accent-color radial wash so the foreground
/// content (lifted art + card) sits on a richer, track-tied surface.
/// Hidden whenever the card is in its compact state.
///
/// **Blur source**: `LockScreenBlurService`, owned by the widget
/// controller. The service computes blurs on a background queue and
/// publishes the result; the view never blocks the main thread.
struct LockScreenBackdropView: View {
    @ObservedObject var musicState: NowPlayingState
    @ObservedObject var cardState: LockScreenMusicCardState
    @ObservedObject var blurService: LockScreenBlurService

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1 — blurred art + accent wash, covers the whole
            // screen. Sits below the loginwindow's clock + login UI in
            // z-order (system UI hidden behind us).
            ZStack {
                // Base layer: blurred art once it lands, dark fill until
                // then (or if the blur fails / there's no art).
                if let blurred = blurService.blurredArtwork {
                    Image(nsImage: blurred)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .overlay(Color.black.opacity(0.55))
                } else {
                    Color.black.opacity(0.75)
                }

                // Accent radial wash — driven by the decoded artwork, NOT
                // the blurred image, so the track-tied color appears the
                // moment the backdrop is shown rather than waiting on the
                // background-thread blur. Previously this lived inside the
                // `if let blurred` branch, so a slow or failed blur left a
                // flat black backdrop with no color at all (the "background
                // color sometimes doesn't show up" bug).
                RadialGradient(
                    colors: [
                        ArtworkColor.accent(for: musicState.artwork).opacity(0.22),
                        .clear
                    ],
                    center: .center,
                    startRadius: 60,
                    endRadius: 800
                )
            }
            .ignoresSafeArea()

            // Layer 2 — our own clock drawn on top of the backdrop so
            // the visual matches macOS's lock-screen clock even though
            // the real one is buried behind us. Date above time, both
            // SF Pro Rounded bold with a vertical light-to-darker
            // gradient that approximates the system clock's vibrant
            // "shine".
            clockOverlay
                .padding(.top, 90)
        }
        // Visible when artwork is lifted AND the user isn't typing.
        // Typing fades the whole backdrop (including our drawn clock)
        // to expose the real macOS lock-screen clock + login UI
        // underneath, so the user can type their password.
        //
        // Fully opaque (1.0). The 0.92 safety cap was reverted at the
        // user's request — full opacity for a cleaner look. Defense
        // for the lock-screen path now relies on `keyboardActive`
        // fading the backdrop the moment the user starts typing, plus
        // `LockScreenWidgetPanel.canBecomeKey = false` ensuring keys
        // always reach loginwindow regardless of opacity.
        .opacity(cardState.isArtworkLifted && !cardState.keyboardActive ? 1.0 : 0)
        .animation(.easeInOut(duration: 0.45), value: cardState.isArtworkLifted)
        .animation(.easeInOut(duration: 0.25), value: cardState.keyboardActive)
        .animation(.easeInOut(duration: 0.6), value: blurService.blurredArtwork)
        // Drive the blur service from the upstream BYTE stream rather
        // than the decoded NSImage — same album art doesn't re-emit
        // since the adapter dedups at source, so the service stays
        // idle on mid-track payload re-emits.
        .onChange(of: musicState.artworkData) { _, newData in
            blurService.update(artworkData: newData)
        }
        .onAppear {
            blurService.update(artworkData: musicState.artworkData)
        }
    }

    /// Re-renders every second via TimelineView so the displayed
    /// minute flips correctly without an external timer. macOS Tahoe
    /// doesn't surface a lock-screen-clock customization API; this is
    /// a best-effort visual match: SF Pro Rounded semibold, date sits
    /// above the time, both white (the real clock picks up wallpaper
    /// vibrancy — we render against our own dark backdrop so plain
    /// white is the closest sensible approximation).
    private var clockOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: -12) {
                Text(Self.dateString(for: ctx.date))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Self.clockGradient)
                Text(Self.timeString(for: ctx.date))
                    .font(.system(size: 128, weight: .bold))
                    .foregroundStyle(Self.clockGradient)
                    .monospacedDigit()
            }
        }
    }

    /// Subtle top-bright → bottom-soft vertical fade. Closest cheap
    /// approximation of the system clock's vibrant-material shine.
    private static let clockGradient = LinearGradient(
        stops: [
            .init(color: .white, location: 0.0),
            .init(color: .white.opacity(0.88), location: 0.45),
            .init(color: .white.opacity(0.62), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Matches the macOS lock-screen clock format: NO AM/PM marker.
    /// Honors the user's 24h preference (detected by checking whether
    /// the locale's `j` template emits an `a` — AM/PM symbol). 12h
    /// locales get "h:mm" (e.g. "11:44"); 24h locales get "H:mm"
    /// (e.g. "23:44"). Either way the marker is suppressed.
    private static func timeString(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        let probe = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        f.dateFormat = probe.contains("a") ? "h:mm" : "H:mm"
        return f.string(from: date)
    }

    /// "Mon May 25" — short weekday + short month + day, no comma.
    /// Hardcoded format string (not template) so the comma in en_US's
    /// preferred template-derived format ("Mon, May 25") doesn't show.
    private static func dateString(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }

}
