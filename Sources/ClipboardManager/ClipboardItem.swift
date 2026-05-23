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
