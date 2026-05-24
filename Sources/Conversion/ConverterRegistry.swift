import Foundation
import UniformTypeIdentifiers

/// Combines the registered converters and answers the only two questions
/// the rest of the app cares about: "what can I convert this file to?"
/// and "give me the converter that does this pair." Both queries respect
/// the user's category toggles (image / document) in ConversionSettings.
///
/// New converters (Word→PDF, OCR, video) plug in by appending to
/// `converters` — no changes elsewhere required.
@MainActor
final class ConverterRegistry {
    private let converters: [any Converter]
    private let settings: ConversionSettings

    init(settings: ConversionSettings) {
        self.settings = settings
        self.converters = [
            ImageConverter(),
            PDFConverter(),
        ]
    }

    /// All output UTTypes currently available for the given input,
    /// after applying category toggles. Preserves first-seen order so
    /// the context menu order is stable.
    func outputs(for input: UTType) -> [UTType] {
        var seen = Set<UTType>()
        var ordered: [UTType] = []
        for converter in converters where isEnabled(converter.category) {
            for output in converter.outputs(for: input) where !seen.contains(output) {
                seen.insert(output)
                ordered.append(output)
            }
        }
        return ordered
    }

    /// First converter (in registration order) able to handle the given
    /// pair. Returns nil if no enabled converter supports it.
    func converter(for input: UTType, to output: UTType) -> Converter? {
        for converter in converters where isEnabled(converter.category) {
            if converter.outputs(for: input).contains(output) {
                return converter
            }
        }
        return nil
    }

    private func isEnabled(_ category: ConversionCategory) -> Bool {
        switch category {
        case .image:    return settings.isImageConversionEnabled
        case .document: return settings.isDocumentConversionEnabled
        }
    }
}
