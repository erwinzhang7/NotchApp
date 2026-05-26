import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Full-screen backdrop that fades in only when the music card's
/// artwork is in its lifted (big) state. Heavy gaussian blur of the
/// album art + a soft accent-color radial wash so the foreground
/// content (lifted art + card) sits on a richer, track-tied surface.
/// Hidden whenever the card is in its compact state.
struct LockScreenBackdropView: View {
    @ObservedObject var musicState: NowPlayingState
    @ObservedObject var cardState: LockScreenMusicCardState

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1 — blurred art + accent wash, covers the whole
            // screen. Sits below the loginwindow's clock + login UI in
            // z-order (system UI hidden behind us).
            ZStack {
                if let blurred = blurredArtwork {
                    Image(nsImage: blurred)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .overlay(Color.black.opacity(0.55))
                        .overlay(
                            RadialGradient(
                                colors: [
                                    ArtworkColor.accent(for: musicState.artwork).opacity(0.22),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 60,
                                endRadius: 800
                            )
                        )
                } else {
                    Color.black.opacity(0.75)
                }
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
        .opacity(cardState.isArtworkLifted && !cardState.keyboardActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.45), value: cardState.isArtworkLifted)
        .animation(.easeInOut(duration: 0.25), value: cardState.keyboardActive)
        .animation(.easeInOut(duration: 0.6), value: musicState.artwork)
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
            VStack(spacing: -4) {
                Text(Self.dateString(for: ctx.date))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Self.clockGradient)
                Text(Self.timeString(for: ctx.date))
                    .font(.system(size: 150, weight: .bold))
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

    private var blurredArtwork: NSImage? {
        guard let art = musicState.artwork else { return nil }
        return Self.cache.image(for: art)
    }

    private static let cache = LockScreenBlurCache()
}

/// One-deep blur cache. Artwork is wholesale-replaced on track change
/// so identity is a stable cache key.
@MainActor
final class LockScreenBlurCache {
    private var lastSource: ObjectIdentifier?
    private var lastResult: NSImage?

    func image(for source: NSImage) -> NSImage? {
        let key = ObjectIdentifier(source)
        if key == lastSource, let lastResult { return lastResult }
        let blurred = Self.blur(source)
        lastSource = key
        lastResult = blurred
        return blurred
    }

    nonisolated private static func blur(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ci.clampedToExtent()
        blur.radius = 80

        let ctx = CIContext()
        guard let output = blur.outputImage,
              let cg = ctx.createCGImage(output, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: image.size)
    }
}
