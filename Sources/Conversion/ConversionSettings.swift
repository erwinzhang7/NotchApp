import Combine
import Foundation
import UniformTypeIdentifiers

/// Persisted preferences for the conversion feature. All four settings
/// drive both the context-menu visibility and the runtime behavior of
/// ConversionService.
@MainActor
final class ConversionSettings: ObservableObject {
    @Published var isImageConversionEnabled: Bool {
        didSet { UserDefaults.standard.set(isImageConversionEnabled, forKey: Keys.imageEnabled) }
    }

    @Published var isDocumentConversionEnabled: Bool {
        didSet { UserDefaults.standard.set(isDocumentConversionEnabled, forKey: Keys.docEnabled) }
    }

    @Published var defaultOutputFormat: ImageFormat {
        didSet { UserDefaults.standard.set(defaultOutputFormat.rawValue, forKey: Keys.defaultFormat) }
    }

    /// When true, the source file is deleted on a successful conversion
    /// and its shelf entry is replaced by the new file. Defaults to FALSE
    /// — non-destructive by default per the spec.
    @Published var deleteOriginalAfterConversion: Bool {
        didSet { UserDefaults.standard.set(deleteOriginalAfterConversion, forKey: Keys.deleteOriginal) }
    }

    /// The default output as a UTType — convenience for the context menu
    /// and ConversionService.
    var defaultOutputUTType: UTType { defaultOutputFormat.utType }

    private enum Keys {
        static let imageEnabled    = "conversion.imageEnabled"
        static let docEnabled      = "conversion.documentEnabled"
        static let defaultFormat   = "conversion.defaultOutputFormat"
        static let deleteOriginal  = "conversion.deleteOriginalAfterConversion"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.imageEnabled:   true,
            Keys.docEnabled:     true,
            Keys.defaultFormat:  ImageFormat.jpeg.rawValue,
            Keys.deleteOriginal: false,
        ])
        self.isImageConversionEnabled    = defaults.bool(forKey: Keys.imageEnabled)
        self.isDocumentConversionEnabled = defaults.bool(forKey: Keys.docEnabled)
        self.deleteOriginalAfterConversion = defaults.bool(forKey: Keys.deleteOriginal)

        // Load and validate the default output format against the launch-
        // time encoding self-test. If the saved choice (e.g. a WebP that
        // the user picked before the self-test was added) can't be
        // encoded on this system, fall back to JPEG and persist the
        // correction so the picker shows the right value on next open.
        let rawFormat = defaults.string(forKey: Keys.defaultFormat) ?? ImageFormat.jpeg.rawValue
        let parsed = ImageFormat(rawValue: rawFormat) ?? .jpeg
        let writable = ImageEncodingCapability.writableFormats
        let validated: ImageFormat
        if writable.contains(parsed) {
            validated = parsed
        } else {
            // Prefer JPEG; if for some reason JPEG isn't writable either,
            // take whatever the safety floor gave us.
            validated = writable.contains(.jpeg) ? .jpeg : (writable.first ?? .jpeg)
            NSLog("[Conversion] saved default format \(parsed.displayName) isn't writable on this system; resetting to \(validated.displayName)")
            defaults.set(validated.rawValue, forKey: Keys.defaultFormat)
        }
        self.defaultOutputFormat = validated
    }
}
