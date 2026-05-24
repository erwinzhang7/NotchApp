import Foundation
import UniformTypeIdentifiers

/// Pluggable conversion unit. Implementations declare which input UTTypes
/// they handle and what output UTTypes are valid for each, and perform
/// the actual conversion writing to disk.
///
/// Async to keep image/PDF work off the main thread. Returns the URLs of
/// every output file written — image-to-image and image→PDF return one
/// URL; PDF→image returns one URL per page.
protocol Converter {
    /// Category the user gates via Settings (image vs document). The
    /// registry filters converters whose category is disabled.
    var category: ConversionCategory { get }

    /// Valid output UTTypes for the given input. Empty when the converter
    /// can't handle this input type.
    func outputs(for input: UTType) -> [UTType]

    /// Perform the conversion. `folder` is the destination directory
    /// (usually the source file's folder, for the alongside-write
    /// behavior). `stem` is the desired base filename without extension.
    /// The converter applies the right extension(s) and disambiguates
    /// against existing files via FileNaming.uniqueURL.
    func convert(
        source: URL,
        to outputType: UTType,
        folder: URL,
        stem: String
    ) async throws -> [URL]
}

/// Toggle category for Settings gating. The user can disable image
/// conversion (image-to-image) and document conversion (PDF↔image)
/// independently.
enum ConversionCategory {
    case image
    case document
}

/// Errors surfaced to the user via the shelf banner. `LocalizedError`
/// means the underlying `localizedDescription` is what gets shown.
enum ConversionError: LocalizedError {
    case unsupportedInput(UTType)
    case noConverter(input: UTType, output: UTType)
    case cannotResolveSource(name: String)
    case cannotReadSource(URL)
    case cannotCreateDestination(URL, type: UTType)
    case cannotWriteOutput(URL)
    case pdfNoPages(URL)
    case imageDecodingFailed(URL)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedInput(let t):
            return "Can't convert files of type \(t.identifier)."
        case .noConverter(let i, let o):
            return "No converter for \(displayName(i)) → \(displayName(o))."
        case .cannotResolveSource(let name):
            return "Couldn't locate \(name) anymore (was it moved or deleted?)."
        case .cannotReadSource(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .cannotCreateDestination(let url, let type):
            return "Couldn't create \(displayName(type)) destination at \(url.lastPathComponent). The folder may be read-only."
        case .cannotWriteOutput(let url):
            return "Couldn't write \(url.lastPathComponent). The folder may be read-only."
        case .pdfNoPages(let url):
            return "\(url.lastPathComponent) has no pages."
        case .imageDecodingFailed(let url):
            return "Couldn't decode the image in \(url.lastPathComponent)."
        case .underlying(let err):
            return err.localizedDescription
        }
    }

    private func displayName(_ type: UTType) -> String {
        type.preferredFilenameExtension?.uppercased()
        ?? type.localizedDescription
        ?? type.identifier
    }
}

/// Output-naming helpers. Single source of truth for writing alongside
/// the original without overwriting existing files.
enum FileNaming {
    /// First available URL in `folder` for `stem.ext`. If it collides,
    /// appends `-1`, `-2`, … to the stem until a free slot is found.
    static func uniqueURL(in folder: URL, stem: String, extension ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(stem)-\(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

/// User-facing image format catalogue. Used by the default-output picker
/// in Settings and for display names in the context menu. The UTType
/// values are the truth source; `displayName` is the menu label.
enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, webp, tiff, gif, bmp

    var id: String { rawValue }

    /// WebP UTI on macOS — ImageIO supports both read and write since 14.
    private static let webpType = UTType("org.webmproject.webp")!

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png:  return .png
        case .heic: return .heic
        case .webp: return Self.webpType
        case .tiff: return .tiff
        case .gif:  return .gif
        case .bmp:  return .bmp
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .tiff: return "TIFF"
        case .gif:  return "GIF"
        case .bmp:  return "BMP"
        }
    }

    /// Reverse lookup so the registry / context-menu code can show a
    /// human label for a UTType the user might pick.
    static func displayName(for utType: UTType) -> String {
        for format in ImageFormat.allCases where format.utType == utType {
            return format.displayName
        }
        if utType == .pdf { return "PDF" }
        return utType.preferredFilenameExtension?.uppercased()
            ?? utType.localizedDescription
            ?? utType.identifier
    }
}

/// All image UTTypes shared by the converters. Single source of truth
/// for "the images we recognise".
enum SupportedImageTypes {
    static let all: [UTType] = ImageFormat.allCases.map(\.utType)
    static let allSet: Set<UTType> = Set(all)
}
