import Combine
import Foundation
import UniformTypeIdentifiers

/// Drives the actual convert action from the UI:
///   - Looks up a converter for (input, output).
///   - Resolves the shelf item's real path via its bookmark (handles
///     moved files).
///   - Hands off to the converter with `(folder, stem)` = source's
///     directory and basename.
///   - Adds each written URL to the shelf as a draggable item.
///   - If the delete-original toggle is on, removes the source file
///     and replaces its shelf entry with the new one.
///   - Surfaces any thrown error as a transient banner via
///     `lastError`, which auto-clears after a few seconds.
@MainActor
final class ConversionService: ObservableObject {
    /// Most-recent user-facing error string. The shelf strip view shows
    /// it as a small banner and we auto-clear so stale errors don't
    /// linger after the user has moved on.
    @Published private(set) var lastError: String?

    private let registry: ConverterRegistry
    private let settings: ConversionSettings
    private let shelfStore: FileShelfStore
    private var errorClearTask: Task<Void, Never>?

    /// How long to display a transient error banner before hiding it.
    private static let errorVisibleDuration: Duration = .seconds(5)

    init(registry: ConverterRegistry, settings: ConversionSettings, shelfStore: FileShelfStore) {
        self.registry = registry
        self.settings = settings
        self.shelfStore = shelfStore
    }

    func convert(item: FileShelfItem, to outputType: UTType) async {
        guard let inputType = item.utType else {
            surface(ConversionError.unsupportedInput(.data))
            return
        }
        guard let converter = registry.converter(for: inputType, to: outputType) else {
            surface(ConversionError.noConverter(input: inputType, output: outputType))
            return
        }
        guard let sourceURL = shelfStore.resolvedURL(for: item) else {
            surface(ConversionError.cannotResolveSource(name: item.displayName))
            return
        }

        let folder = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent

        do {
            let outputs = try await converter.convert(
                source: sourceURL,
                to: outputType,
                folder: folder,
                stem: stem
            )
            NSLog("[Conversion] \(sourceURL.lastPathComponent) → [\(outputs.map { $0.lastPathComponent }.joined(separator: ", "))]")

            for url in outputs {
                shelfStore.add(url: url)
            }

            if settings.deleteOriginalAfterConversion {
                deleteSource(sourceURL, item: item)
            }
        } catch {
            NSLog("[Conversion] failed \(sourceURL.lastPathComponent) → \(outputType.identifier): \(error.localizedDescription)")
            surface(error)
        }
    }

    /// Best-effort cleanup. If removing the file fails (permission,
    /// locked, etc.) we keep both files and surface a warning so the
    /// user knows their toggle didn't fully apply.
    private func deleteSource(_ url: URL, item: FileShelfItem) {
        do {
            try FileManager.default.removeItem(at: url)
            shelfStore.remove(item)
        } catch {
            NSLog("[Conversion] couldn't delete original \(url.lastPathComponent): \(error.localizedDescription)")
            surface("Converted, but couldn't delete original: \(error.localizedDescription)")
        }
    }

    // MARK: - Error surfacing

    private func surface(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        surface(message)
    }

    private func surface(_ message: String) {
        errorClearTask?.cancel()
        lastError = message
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.errorVisibleDuration)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    /// Manual dismissal — used by the banner's close affordance if we
    /// ever add one. Also called by the shelf when it clears.
    func dismissError() {
        errorClearTask?.cancel()
        errorClearTask = nil
        lastError = nil
    }
}
