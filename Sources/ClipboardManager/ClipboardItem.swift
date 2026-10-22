import AppKit
import Foundation

/// One captured clipboard event. Lives in memory only — never serialized to disk.
struct ClipboardItem: Identifiable {
    let id: UUID = UUID()
    let kind: Kind
    let capturedAt: Date

    enum Kind {
        case text(String)
        case image(ImagePayload)
        case files(FilePayload)
    }
}

/// Full image kept in RAM (size-capped at capture time) plus a downscaled thumbnail for display.
struct ImagePayload {
    let image: NSImage
    let thumbnail: NSImage
    /// Hash of the underlying bytes, used for consecutive-dedup.
    let dataHash: Int
    /// Size of the pasteboard bytes the image was decoded from. Stands in
    /// for the payload's memory cost when the store trims history.
    let byteCount: Int
}

/// File copies are stored as bookmark references, not byte copies. Re-copying resolves them back to URLs.
struct FilePayload {
    let files: [FileRef]
}

struct FileRef {
    let url: URL
    let bookmark: Data
    let displayName: String
    let icon: NSImage
}

extension ClipboardItem {
    /// Approximate RAM held by this entry, for the store's history budget.
    var byteCost: Int {
        switch kind {
        case .text(let s):
            return s.utf8.count
        case .image(let p):
            return p.byteCount
        case .files(let p):
            return p.files.reduce(0) { $0 + $1.bookmark.count }
        }
    }

    /// Stable per-content signature used to suppress consecutive duplicate captures.
    var fingerprint: String {
        switch kind {
        case .text(let s):
            return "text:\(s.hashValue)"
        case .image(let p):
            return "image:\(p.dataHash)"
        case .files(let p):
            return "files:" + p.files.map(\.url.path).joined(separator: "|")
        }
    }
}
