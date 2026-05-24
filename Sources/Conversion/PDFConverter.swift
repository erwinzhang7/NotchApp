import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF ↔ image conversion via PDFKit + ImageIO. Handles both directions:
///   - PDF → image: rasterises each page at ~200 DPI to the chosen image
///     format. A 5-page PDF produces 5 output files named
///     `<stem>-page-N.<ext>`.
///   - image → PDF: wraps a single image in a one-page PDF. Multi-image
///     combine isn't wired up because the shelf doesn't support
///     multi-select yet; the protocol's single-source signature would
///     need to widen for that.
struct PDFConverter: Converter {
    let category: ConversionCategory = .document

    /// PDF coordinates are in points (1/72 inch). 200 DPI is a good
    /// balance between fidelity and file size for screen-targeted
    /// rasterisation.
    private static let renderDPI: CGFloat = 200

    func outputs(for input: UTType) -> [UTType] {
        if input == .pdf {
            // PDF → image. PDFKit renders pages to NSImage, but the
            // actual file write goes through ImageIO — so the same
            // encoder self-test applies here as for image-to-image.
            return SupportedImageTypes.all.filter { ImageEncodingCapability.writableTypes.contains($0) }
        }
        if SupportedImageTypes.allSet.contains(input) {
            // image → PDF via PDFKit; not subject to the ImageIO probe.
            return [.pdf]
        }
        return []
    }

    func convert(
        source: URL,
        to outputType: UTType,
        folder: URL,
        stem: String
    ) async throws -> [URL] {
        if outputType == .pdf {
            return try await imageToPDF(source: source, folder: folder, stem: stem)
        } else {
            return try await pdfToImages(source: source, outputType: outputType, folder: folder, stem: stem)
        }
    }

    // MARK: - image → PDF

    private func imageToPDF(source: URL, folder: URL, stem: String) async throws -> [URL] {
        let destination = FileNaming.uniqueURL(in: folder, stem: stem, extension: "pdf")
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: source) else {
                throw ConversionError.imageDecodingFailed(source)
            }
            guard let page = PDFPage(image: image) else {
                throw ConversionError.imageDecodingFailed(source)
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            if !doc.write(to: destination) {
                throw ConversionError.cannotWriteOutput(destination)
            }
        }.value
        return [destination]
    }

    // MARK: - PDF → images

    private func pdfToImages(
        source: URL,
        outputType: UTType,
        folder: URL,
        stem: String
    ) async throws -> [URL] {
        guard let doc = PDFDocument(url: source) else {
            throw ConversionError.cannotReadSource(source)
        }
        guard doc.pageCount > 0 else {
            throw ConversionError.pdfNoPages(source)
        }

        // Precompute output URLs on main (FileNaming touches FileManager;
        // safe off-main but we don't need to). Then render off-main.
        let ext = outputType.preferredFilenameExtension ?? "img"
        var plannedURLs: [URL] = []
        plannedURLs.reserveCapacity(doc.pageCount)
        for pageIndex in 0..<doc.pageCount {
            let pageStem = "\(stem)-page-\(pageIndex + 1)"
            plannedURLs.append(FileNaming.uniqueURL(in: folder, stem: pageStem, extension: ext))
        }

        let pageCount = doc.pageCount
        let renderDPI = Self.renderDPI
        let writtenURLs: [URL] = try await Task.detached(priority: .userInitiated) {
            // Re-open PDFDocument inside the detached task — PDFDocument
            // isn't Sendable, and PDFKit is fine being driven off-main.
            guard let doc = PDFDocument(url: source) else {
                throw ConversionError.cannotReadSource(source)
            }
            var results: [URL] = []
            for pageIndex in 0..<pageCount {
                guard let page = doc.page(at: pageIndex) else {
                    throw ConversionError.pdfNoPages(source)
                }
                let pageBounds = page.bounds(for: .mediaBox)
                let scale = renderDPI / 72.0
                let pixelSize = CGSize(
                    width:  pageBounds.width  * scale,
                    height: pageBounds.height * scale
                )
                let image = page.thumbnail(of: pixelSize, for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw ConversionError.imageDecodingFailed(source)
                }
                let dest = plannedURLs[pageIndex]
                try Self.writeCGImage(cgImage, to: dest, type: outputType)
                results.append(dest)
            }
            return results
        }.value

        return writtenURLs
    }

    private static func writeCGImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.cannotCreateDestination(url, type: type)
        }
        var properties: [CFString: Any] = [:]
        if type == .jpeg || type == .heic || type == ImageFormat.webp.utType {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.85
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw ConversionError.cannotWriteOutput(url)
        }
    }
}
