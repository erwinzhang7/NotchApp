import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launch-time self-test of which image formats ImageIO can actually
/// ENCODE on this machine + macOS combination. The system's
/// `CGImageDestinationCopyTypeIdentifiers()` is the source of truth —
/// even when an extension is "supported" in the abstract, the encoder
/// for it can be missing on a particular OS build (confirmed: WebP
/// fails to encode on the user's macOS 26, even though WebP input
/// decodes fine).
///
/// Intersected with our `ImageFormat` catalogue to produce the set of
/// formats we offer as conversion targets. Input/decoding is unaffected
/// — WebP stays a valid SOURCE for `WebP → JPEG`, just not a valid
/// destination.
///
/// PDF is separate (PDFKit, not ImageIO) and is never filtered by this.
enum ImageEncodingCapability {
    /// Detected writable image formats, in `ImageFormat.allCases` order,
    /// guaranteed non-empty: if the system probe returns nothing the
    /// safety floor [JPEG, PNG] is substituted and a loud warning logged.
    /// Resolved lazily on first access — force-accessed from
    /// ConversionManager.Services.init so the test runs at app launch.
    static let writableFormats: [ImageFormat] = probe()

    /// UTType view for converters that filter by output type.
    static let writableTypes: Set<UTType> = Set(writableFormats.map(\.utType))

    private static func probe() -> [ImageFormat] {
        let systemUTIs = (CGImageDestinationCopyTypeIdentifiers() as NSArray) as? [String] ?? []
        let systemSet = Set(systemUTIs)
        let detected = ImageFormat.allCases.filter { systemSet.contains($0.utType.identifier) }

        let detectedNames = detected.map(\.displayName).joined(separator: ", ")
        NSLog("[Conversion] image encoding self-test — writable formats: [\(detectedNames)]")

        // Log skipped formats so the user can see exactly what was rejected.
        let skipped = ImageFormat.allCases.filter { !systemSet.contains($0.utType.identifier) }
        if !skipped.isEmpty {
            NSLog("[Conversion] image encoding self-test — NOT writable on this system: [\(skipped.map(\.displayName).joined(separator: ", "))]")
        }

        if detected.isEmpty {
            // Spec'd safety floor — should never happen on a real macOS,
            // but if ImageIO somehow reports zero writable types, at
            // least keep JPEG + PNG so the feature isn't dead in the
            // water. Log loudly so the cause can be tracked down.
            NSLog("[Conversion] ⚠️ image encoding self-test returned EMPTY — falling back to safety floor [JPEG, PNG]")
            return [.jpeg, .png]
        }
        return detected
    }
}
