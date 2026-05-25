import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Full-screen backdrop behind the ambient layout. When music is playing
/// and we have artwork, shows a heavily-blurred, brightness-dampened
/// version of the artwork (Apple Music's full-screen treatment). Falls
/// back to a dark gradient when there's no artwork.
struct AmbientBackdrop: View {
    @ObservedObject var state: NowPlayingState

    var body: some View {
        ZStack {
            if let blurred = blurredArtwork {
                Image(nsImage: blurred)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .overlay(
                        // Darken so the foreground glass cards remain
                        // legible regardless of the artwork's brightness.
                        Color.black.opacity(0.55)
                    )
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.07, blue: 0.10),
                        Color(red: 0.02, green: 0.02, blue: 0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: state.artwork)
    }

    /// Cached blur — recomputed when the artwork pointer changes.
    private var blurredArtwork: NSImage? {
        guard let art = state.artwork else { return nil }
        return Self.blurCache.image(for: art)
    }

    /// Tiny LRU keyed by the source NSImage's pointer (artwork is updated
    /// wholesale on track change, not mutated in place, so identity is a
    /// stable cache key).
    private static let blurCache = BlurCache()
}

/// One-deep blur cache: only the most recently requested artwork is kept,
/// since the ambient screen only ever shows one track at a time.
@MainActor
final class BlurCache {
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
