import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image-to-image conversion via ImageIO. Supports all formats in
/// `SupportedImageTypes` (WebP, PNG, JPEG, HEIC, TIFF, GIF, BMP).
/// CGImageDestinationCopyTypeIdentifiers on macOS 14+ confirms both
/// read and write support for the full set.
struct ImageConverter: Converter {
    let category: ConversionCategory = .image

    /// JPEG/HEIC/WebP are lossy; this controls their encode quality.
    /// Spec asks for a sensible default; 0.85 hits the usual quality/
    /// size sweet spot.
    private static let lossyQuality: CGFloat = 0.85

    func outputs(for input: UTType) -> [UTType] {
        guard SupportedImageTypes.allSet.contains(input) else { return [] }
        // Filter by the launch-time self-test — only formats ImageIO can
        // actually ENCODE on this system are offered. Input is unaffected
        // (we still accept WebP sources even when WebP output is dropped).
        return SupportedImageTypes.all.filter {
            $0 != input && ImageEncodingCapability.writableTypes.contains($0)
        }
    }

    func convert(
        source: URL,
        to outputType: UTType,
        folder: URL,
        stem: String
    ) async throws -> [URL] {
        let ext = outputType.preferredFilenameExtension ?? "img"
        let destination = FileNaming.uniqueURL(in: folder, stem: stem, extension: ext)
        try await Task.detached(priority: .userInitiated) {
            try Self.performConversion(source: source, to: outputType, destination: destination)
        }.value
        return [destination]
    }

    /// Synchronous worker run off-main. ImageIO is thread-safe and
    /// CGImageDestinationAddImageFromSource preserves metadata while
    /// re-encoding into the new container.
    private static func performConversion(source: URL, to outputType: UTType, destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.cannotReadSource(source)
        }
        guard CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.imageDecodingFailed(source)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.cannotCreateDestination(destination, type: outputType)
        }

        var properties: [CFString: Any] = [:]
        if isLossy(outputType) {
            properties[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        }

        CGImageDestinationAddImageFromSource(dest, imageSource, 0, properties as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw ConversionError.cannotWriteOutput(destination)
        }
    }

    private static func isLossy(_ type: UTType) -> Bool {
        type == .jpeg
        || type == .heic
        || type == ImageFormat.webp.utType
    }
}
