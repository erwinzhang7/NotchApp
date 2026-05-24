import AppKit
import Foundation
import UniformTypeIdentifiers

/// One file currently held in the shelf. Stored by REFERENCE (URL + bookmark), not by
/// byte copy — same privacy model the clipboard module uses for file-URL captures.
struct FileShelfItem: Identifiable {
    let id: UUID = UUID()
    /// URL captured at drop time. May go stale if the file is moved later; the bookmark
    /// is the source of truth for `resolvedURL`.
    let url: URL
    /// Bookmark used to re-locate the file later, even if it has moved.
    let bookmark: Data
    let displayName: String
    let icon: NSImage
    let addedAt: Date
    /// Resolved UTType (preferring the system's content-type query, falling
    /// back to the filename extension). Nil for files of unknown type.
    /// Used by the conversion context menu to decide what targets to offer.
    let utType: UTType?
}
