import AppKit
import Foundation
import UniformTypeIdentifiers

/// Pattern lifted from boring.notch's `NSItemProvider+LoadHelpers.swift`:
/// the high-level callers ask "give me a file URL / a web URL / text / raw
/// data," and these helpers translate the provider's various return shapes
/// (URL, Data carrying a URL string, raw String, bookmark Data) into a
/// single answer.
extension NSItemProvider {
    /// True file dragged from the filesystem (Finder, an editor's project
    /// pane, etc.). Returns nil if the provider doesn't have a fileURL.
    func extractFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await loadFileURL(typeIdentifier: UTType.fileURL.identifier)
    }

    /// Web URL (e.g. a link dragged from Safari's address bar). Filters out
    /// the file:// variant so callers can distinguish links from files.
    func extractWebURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        guard let url = await loadURL(typeIdentifier: UTType.url.identifier) else { return nil }
        guard url.scheme != nil, !url.isFileURL else { return nil }
        return url
    }

    /// Plain text (selected text dragged from any editor / browser).
    func extractText() async -> String? {
        for id in [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
            where hasItemConformingToTypeIdentifier(id) {
            if let s = await loadText(typeIdentifier: id), !s.isEmpty { return s }
        }
        return nil
    }

    /// Raw data drag — used to catch SwiftUI file-promise drags (Safari
    /// images, Slack file previews, etc.). The system stages the payload in
    /// a temp folder under `com.apple.SwiftUI.filePromises`; we read it, then
    /// clean up so we don't leak the staging directory.
    func extractPromisedData() async -> (data: Data, suggestedName: String?)? {
        guard hasItemConformingToTypeIdentifier(UTType.data.identifier) else { return nil }
        // Snapshot `suggestedName` before crossing into the @Sendable
        // continuation closure so NSItemProvider (non-Sendable) isn't
        // captured by ref.
        let providerSuggestedName = self.suggestedName
        return await withCheckedContinuation { (cont: CheckedContinuation<(Data, String?)?, Never>) in
            loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { item, _ in
                if let url = item as? URL,
                   url.absoluteString.contains("com.apple.SwiftUI.filePromises"),
                   let data = try? Data(contentsOf: url) {
                    let name = providerSuggestedName ?? url.lastPathComponent
                    // Best-effort: remove the staged file (and its parent if
                    // it ends up empty) so the system temp directory doesn't
                    // accumulate file-promise leftovers.
                    let folder = url.deletingLastPathComponent()
                    try? FileManager.default.removeItem(at: url)
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                       contents.isEmpty {
                        try? FileManager.default.removeItem(at: folder)
                    }
                    cont.resume(returning: (data, name))
                } else if let data = item as? Data {
                    cont.resume(returning: (data, providerSuggestedName))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Low-level

    private func loadFileURL(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    cont.resume(returning: URL(string: string) ?? URL(fileURLWithPath: string))
                } else if let string = item as? String {
                    cont.resume(returning: URL(string: string) ?? URL(fileURLWithPath: string))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8),
                          let url = URL(string: string) {
                    cont.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(typeIdentifier: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let string = item as? String {
                    cont.resume(returning: string)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    cont.resume(returning: string)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
