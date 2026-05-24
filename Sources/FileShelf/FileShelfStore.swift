import AppKit
import Foundation
import UniformTypeIdentifiers

/// Authoritative in-memory list of files held in the shelf. Lives in RAM only — never
/// serialized to disk, no UserDefaults, no on-disk shelf database. Files are referenced
/// by URL + bookmark, not byte-copied, so the shelf carries no file content of its own.
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem] = []

    var hasItems: Bool { !items.isEmpty }

    // MARK: - Mutations

    /// Add a file URL to the shelf. De-duped by URL (same path won't be added twice).
    func add(url: URL) {
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
            utType: utType
        )
        items.append(item)
    }

    func remove(_ item: FileShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        items.removeAll()
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

    /// Accepts items produced by SwiftUI's `.onDrop`. Loads each provider's file URL on a
    /// background callback, then dispatches the actual add back to the main actor.
    func accept(providers: [NSItemProvider]) async {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await Self.loadFileURL(from: provider)
                }
            }
            for await url in group {
                guard let url else { continue }
                await MainActor.run { self.add(url: url) }
            }
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        // Prefer the typed object loader (handles security-scoped wrappers cleanly).
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
        }
        // Fallback: load the raw fileURL representation and decode it ourselves.
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
