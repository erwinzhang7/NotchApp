import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Extracts a single accent color from album artwork and clamps it into
/// a band that's readable against a dark backdrop. Uses CIAreaAverage —
/// fast, cheap, "warmth of the artwork" — clamped so neither very dark
/// nor very washed-out albums kill contrast on the scrubber / tint.
///
/// Cached one-deep (track changes replace the artwork wholesale, so
/// identity of the NSImage is a stable cache key).
@MainActor
enum ArtworkColor {
    private static var cacheKey: ObjectIdentifier?
    private static var cached: Color?

    static func accent(for image: NSImage?) -> Color {
        guard let image else {
            cacheKey = nil
            cached = nil
            return defaultAccent
        }
        let key = ObjectIdentifier(image)
        if key == cacheKey, let cached { return cached }

        let raw = sampleAverage(from: image) ?? defaultAccent
        let result = clampForContrast(raw)
        cacheKey = key
        cached = result
        return result
    }

    /// Fall-back when artwork is missing or sampling fails — neutral
    /// warm-white that reads as "white-ish" but never strident.
    static let defaultAccent: Color = Color(white: 0.95)

    private static func sampleAverage(from image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = ci.extent

        guard let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Color(
            .sRGB,
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0,
            opacity: 1.0
        )
    }

    /// Push the sampled color into a readable band: minimum brightness
    /// so dark album art doesn't vanish on the scrubber, and a
    /// saturation cap so monochrome covers don't print as pure white /
    /// pure red. Operates in HSB space.
    private static func clampForContrast(_ color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let clampedB = min(max(b, 0.55), 0.92)
        let clampedS = min(s, 0.7)

        let out = NSColor(hue: h, saturation: clampedS, brightness: clampedB, alpha: 1.0)
        return Color(nsColor: out)
    }
}
