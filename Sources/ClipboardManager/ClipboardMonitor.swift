import AppKit
import Foundation

/// Polls NSPasteboard.general for new copies and pushes captured items into the store.
/// Polling (not notifications) because NSPasteboard exposes no change notification —
/// this is the standard pattern. The check is just an Int compare; reads only happen on change.
final class ClipboardMonitor {
    /// Skip items larger than this. Bounds RAM growth from single huge images.
    static let maxImageBytes: Int = 20 * 1024 * 1024

    /// Display thumbnail max edge length (points).
    static let thumbnailMaxSide: CGFloat = 64

    /// org.nspasteboard.* flags used by password managers and ephemeral copy sources.
    private static let skippedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private let settings: ClipboardSettings
    private let pollInterval: TimeInterval

    private var timer: Timer?
    private var lastChangeCount: Int

    init(
        store: ClipboardStore,
        settings: ClipboardSettings,
        pasteboard: NSPasteboard = .general,
        pollInterval: TimeInterval = 0.5
    ) {
        self.store = store
        self.settings = settings
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        // Treat whatever's already on the pasteboard at startup as "seen" — don't capture it.
        lastChangeCount = pasteboard.changeCount

        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll loop

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // The write we made for paste-on-select bumped changeCount; don't echo it back.
        if current == store.lastInternalChangeCount { return }

        guard let item = capture() else { return }
        store.add(item)
    }

    // MARK: - Capture

    private func capture() -> ClipboardItem? {
        guard let items = pasteboard.pasteboardItems, let first = items.first else { return nil }

        // Privacy: if ANY item on the pasteboard is flagged concealed/transient, skip the entire event.
        let allTypes = items.flatMap { $0.types.map(\.rawValue) }
        if !Self.skippedTypeIdentifiers.isDisjoint(with: allTypes) { return nil }

        let now = Date()

        // 1. File URLs — try first because file copies usually also carry a string fallback.
        if settings.captureFiles {
            if let payload = captureFiles() {
                return ClipboardItem(kind: .files(payload), capturedAt: now)
            }
        }

        // 2. Image.
        if settings.captureImages {
            if let payload = captureImage(from: first) {
                return ClipboardItem(kind: .image(payload), capturedAt: now)
            }
        }

        // 3. Text.
        if settings.captureText {
            if let text = first.string(forType: .string), !text.isEmpty {
                return ClipboardItem(kind: .text(text), capturedAt: now)
            }
        }

        return nil
    }

    private func captureFiles() -> FilePayload? {
        guard
            let read = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            !read.isEmpty
        else { return nil }

        let refs: [FileRef] = read.compactMap { url in
            // Plain bookmark (not byte copy). withSecurityScope is sandbox-only; we're not sandboxed.
            guard let bookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }

            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return FileRef(
                url: url,
                bookmark: bookmark,
                displayName: url.lastPathComponent,
                icon: icon
            )
        }

        return refs.isEmpty ? nil : FilePayload(files: refs)
    }

    private func captureImage(from item: NSPasteboardItem) -> ImagePayload? {
        let data = item.data(forType: .tiff) ?? item.data(forType: .png)
        guard let data else { return nil }
        // RAM bound: skip oversize images entirely rather than truncate.
        guard data.count <= Self.maxImageBytes else { return nil }
        guard let image = NSImage(data: data) else { return nil }

        let thumb = Self.thumbnail(of: image, maxSide: Self.thumbnailMaxSide)
        return ImagePayload(image: image, thumbnail: thumb, dataHash: data.hashValue)
    }

    private static func thumbnail(of image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        guard size.width > maxSide || size.height > maxSide else { return image }

        let scale = min(maxSide / size.width, maxSide / size.height)
        let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: thumbSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
    }
}
