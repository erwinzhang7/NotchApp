import AppKit
import CoreImage

/// Single color extracted from artwork for use as the equalizer tint.
/// Trimmed from DynamicNotch's `NowPlayingArtworkPalette` — they kept
/// a base + highlight pair for a gradient that's used in their
/// expanded lock-screen scrubber. Our equalizer only uses one color,
/// so highlight / gradient / Equatable are stripped.
///
/// Pipeline:
/// 1. CIAreaAverage of the whole image → one RGBA pixel
/// 2. Convert to HSB
/// 3. If saturation < 0.08 (grayscale-ish artwork), produce a neutral
///    white-ish color
/// 4. Otherwise normalize saturation + brightness into a "readable on
///    a dark notch" range
struct NowPlayingArtworkPalette {
    let equalizerBaseColor: NSColor

    static let fallback = Self(
        equalizerBaseColor: NSColor.gray.withAlphaComponent(0.36)
    )
}

enum NowPlayingArtworkPaletteExtractor {
    private static let context = CIContext()

    static func extract(from artworkData: Data?) -> NowPlayingArtworkPalette {
        guard
            let artworkData,
            let inputImage = CIImage(data: artworkData),
            let averageColor = averageColor(from: inputImage)
        else {
            return .fallback
        }

        return normalizePalette(from: averageColor)
    }

    private static func averageColor(from image: CIImage) -> NSColor? {
        let extent = image.extent.integral
        guard !extent.isEmpty else { return nil }

        let extentVector = CIVector(
            x: extent.origin.x,
            y: extent.origin.y,
            z: extent.size.width,
            w: extent.size.height
        )

        guard
            let filter = CIFilter(
                name: "CIAreaAverage",
                parameters: [
                    kCIInputImageKey: image,
                    kCIInputExtentKey: extentVector
                ]
            ),
            let outputImage = filter.outputImage
        else {
            return nil
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return NSColor(
            srgbRed: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: CGFloat(bitmap[3]) / 255
        )
    }

    private static func normalizePalette(from color: NSColor) -> NowPlayingArtworkPalette {
        guard let resolvedColor = color.usingColorSpace(.sRGB) else {
            return .fallback
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        resolvedColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if saturation < 0.08 {
            // Near-grayscale artwork (black/white covers, photos with
            // low chroma). Use a neutral white-ish tone clamped into a
            // legible range against the dark notch.
            let neutralBrightness = min(max(brightness, 0.7), 0.92)
            return .init(
                equalizerBaseColor: NSColor(white: neutralBrightness, alpha: 0.72)
            )
        }

        // Color artwork — boost saturation slightly, clamp brightness
        // so dim covers don't disappear and over-bright ones don't
        // glare against the dark pill.
        let normalizedSaturation = min(max(saturation * 1.12, 0.42), 0.92)
        let normalizedBrightness = min(max(brightness * 1.04, 0.58), 0.94)

        return .init(
            equalizerBaseColor: NSColor(
                hue: hue,
                saturation: normalizedSaturation,
                brightness: normalizedBrightness,
                alpha: 0.88
            )
        )
    }
}
