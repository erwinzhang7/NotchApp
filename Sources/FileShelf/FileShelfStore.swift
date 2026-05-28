import AppKit
import Foundation
import UniformTypeIdentifiers

/// Authoritative in-memory list of files held in the shelf. Lives in RAM only — never
/// serialized to disk, no UserDefaults, no on-disk shelf database. Files are referenced
/// by URL + bookmark, not byte-copied, so the shelf carries no file content of its own.
///
/// Non-file drags (web URLs, selected text, file-promise data) are materialized into
/// temp files under `TemporaryShelfStorage` and tracked with `isTemporary` so the temp
/// is wiped when the item leaves the shelf.
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem] = []

    var hasItems: Bool { !items.isEmpty }

    // MARK: - Mutations

    /// Add a file URL to the shelf. De-duped by URL (same path won't be added twice).
    func add(url: URL, isTemporary: Bool = false) {
        let canonical = url.resolvingSymlinksInPath().path
        guard !items.contains(where: { $0.url.resolvingSymlinksInPath().path == canonical }) else { return }
        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // Prefer the system's content-type query (handles extensionless files,
        // bundle directories, etc.) and fall back to the filename extension.
        let utType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        let item = FileShelfItem(
            url: url,
            bookmark: bookmark,
            displayName: url.lastPathComponent,
            icon: icon,
            addedAt: Date(),
            utType: utType,
            isTemporary: isTemporary
        )
        items.append(item)
    }

    func remove(_ item: FileShelfItem) {
        items.removeAll { $0.id == item.id }
        if item.isTemporary {
            TemporaryShelfStorage.remove(item.url)
        }
    }

    func clearAll() {
        let temps = items.filter(\.isTemporary).map(\.url)
        items.removeAll()
        for url in temps { TemporaryShelfStorage.remove(url) }
    }

    /// Re-resolves the bookmark to a current URL. Falls back to the captured URL if the
    /// bookmark fails to resolve.
    func resolvedURL(for item: FileShelfItem) -> URL? {
        var stale = false
        if let resolved = try? URL(
            resolvingBookmarkData: item.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return resolved
        }
        return FileManager.default.fileExists(atPath: item.url.path) ? item.url : nil
    }

    // MARK: - Drop ingestion

    /// Accepts items produced by SwiftUI's `.onDrop`. For each provider, tries — in order —
    /// a real file URL, a web URL (saved as `.webloc`), a file-promise data drag (Safari
    /// images, Slack file previews; saved with the suggested name), and finally plain text
    /// (saved as `.txt`). Everything ends up as a real file in the shelf, so AirDrop /
    /// drag-out / conversion all work uniformly.
    func accept(providers: [NSItemProvider]) async {
        // (URL, isTemporary) tuples; resolved off the main actor in parallel.
        let landed: [(URL, Bool)] = await withTaskGroup(of: (URL, Bool)?.self) { group in
            for provider in providers {
                group.addTask { await Self.ingest(provider) }
            }
            var out: [(URL, Bool)] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }

        guard !landed.isEmpty else { return }
        await MainActor.run {
            for (url, isTemp) in landed { self.add(url: url, isTemporary: isTemp) }
            Haptics.tap()
        }
    }

    /// Resolution cascade for one provider. Returns the materialized URL plus a
    /// flag indicating whether the file is one of our temps.
    private static func ingest(_ provider: NSItemProvider) async -> (URL, Bool)? {
        if let fileURL = await provider.extractFileURL() {
            return (fileURL, false)
        }
        if let webURL = await provider.extractWebURL() {
            // Web URLs become `.webloc` files. macOS recognizes the extension
            // natively (double-click opens in browser, AirDrop-able as a link).
            if let temp = TemporaryShelfStorage.writeWebloc(webURL, title: provider.suggestedName) {
                return (temp, true)
            }
            return nil
        }
        if let promised = await provider.extractPromisedData() {
            // File-promise drags (Safari images, Slack previews, etc.).
            if let temp = TemporaryShelfStorage.writeData(
                promised.data,
                suggestedName: promised.suggestedName,
                fallbackExtension: "bin"
            ) {
                return (temp, true)
            }
            return nil
        }
        if let text = await provider.extractText() {
            if let temp = TemporaryShelfStorage.writeText(text) {
                return (temp, true)
            }
            return nil
        }
        return nil
    }
}
