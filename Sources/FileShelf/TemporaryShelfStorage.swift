import AppKit
import Foundation

/// Temp-file backing for shelf items born from non-file drags (web URLs,
/// selected text, file-promise data). The shelf is still file-only — each
/// non-file payload gets materialized into a real file here, then handed
/// to the shelf like any other drop. Files written here are flagged on the
/// `FileShelfItem` so the store can clean them up on remove / app exit.
enum TemporaryShelfStorage {
    /// Root directory for all temp shelf files this session. Cleared on
    /// `purgeAll()` (called at app exit).
    private static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchApp", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Writes raw data to a uniquely-named file. `suggestedName` is used
    /// when present, otherwise a UUID stem + the supplied extension.
    static func writeData(_ data: Data, suggestedName: String?, fallbackExtension: String) -> URL? {
        let name = uniqueName(suggestedName: suggestedName, fallbackExtension: fallbackExtension)
        let url = root.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Writes a `.webloc` (XML plist with a URL key) so the shelf entry
    /// behaves like a Safari bookmark — double-clickable from Finder,
    /// AirDropable to another Mac, etc.
    static func writeWebloc(_ url: URL, title: String?) -> URL? {
        let plist: [String: Any] = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else { return nil }
        let stem = title?.nilIfEmpty ?? url.host ?? "Link"
        let name = uniqueName(suggestedName: "\(stem).webloc", fallbackExtension: "webloc")
        let dst = root.appendingPathComponent(name)
        try? data.write(to: dst, options: .atomic)
        return dst
    }

    /// Writes a plain-text snippet to a `.txt` file. Display name is taken
    /// from the first non-empty line, truncated to a reasonable length.
    static func writeText(_ text: String) -> URL? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let stem = firstLine.trimmingCharacters(in: .whitespaces).prefix(40)
        let safeStem = stem.isEmpty ? "Snippet" : sanitize(String(stem))
        let name = uniqueName(suggestedName: "\(safeStem).txt", fallbackExtension: "txt")
        let dst = root.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: dst, options: .atomic)
            return dst
        } catch {
            return nil
        }
    }

    /// Best-effort delete; no-op if the URL isn't actually under our temp root
    /// (defensive — never delete something we didn't write).
    static func remove(_ url: URL) {
        guard url.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipes the entire temp directory. Call on app exit so leftover shelf
    /// temps don't accumulate across runs.
    static func purgeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Naming

    private static func uniqueName(suggestedName: String?, fallbackExtension: String) -> String {
        let base = suggestedName.flatMap { $0.nilIfEmpty } ?? "drop.\(fallbackExtension)"
        let safe = sanitize(base)
        // Collision-avoidance via short UUID prefix so two drags with the
        // same suggested name don't clobber each other.
        return "\(UUID().uuidString.prefix(8))-\(safe)"
    }

    private static func sanitize(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        return raw.components(separatedBy: bad).joined(separator: "_")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
