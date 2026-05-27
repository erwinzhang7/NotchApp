import AppKit
import Combine
import Foundation

/// Authoritative in-memory clipboard history. The single most important property of this type:
/// nothing here is ever persisted. No files, no SQLite, no UserDefaults — items live in RAM
/// and die when the process exits. That's the app's headline privacy guarantee.
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchQuery: String = ""

    /// Fires whenever a TEXT item is newly inserted into the store —
    /// from manual Cmd+C, auto-copy-on-selection, or any other path
    /// that lands in `add()`. AppDelegate subscribes to drive the
    /// "Copied N characters" notch banner. Doesn't fire for images /
    /// file copies (banner is text-only) or for dedup-suppressed adds.
    struct TextCopy: Equatable {
        let characterCount: Int
        let lineCount: Int
    }
    let textCopied = PassthroughSubject<TextCopy, Never>()

    /// Pasteboard.changeCount of the last write *we* performed (paste-on-select).
    /// The monitor uses this to suppress re-capturing our own re-copies.
    private(set) var lastInternalChangeCount: Int = -1

    private let settings: ClipboardSettings
    private var purgeTimer: Timer?
    private var settingsObservation: AnyCancellable?

    init(settings: ClipboardSettings) {
        self.settings = settings
        self.settingsObservation = settings.$autoClearInterval
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleAutoPurge() }
        scheduleAutoPurge()
    }

    // MARK: - Filtered view used by the UI

    /// Search filters text content and file names. Image entries are hidden when a query is active.
    var filteredItems: [ClipboardItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            switch item.kind {
            case .text(let s):
                return s.lowercased().contains(q)
            case .files(let p):
                return p.files.contains { $0.displayName.lowercased().contains(q) }
            case .image:
                return false
            }
        }
    }

    // MARK: - Mutations

    /// Returns true if the item was inserted, false if it was suppressed
    /// by the consecutive-dedup check. Callers (e.g. SelectionMonitor)
    /// use the return value to decide whether to fire downstream effects
    /// like the "Copied N characters" notch banner.
    @discardableResult
    func add(_ item: ClipboardItem) -> Bool {
        // Dedup consecutive identical captures only (per spec).
        if let head = items.first, head.fingerprint == item.fingerprint { return false }
        items.insert(item, at: 0)
        if case .text(let s) = item.kind {
            let lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            textCopied.send(TextCopy(characterCount: s.count, lineCount: max(1, lines)))
        }
        return true
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        items.removeAll()
    }

    // MARK: - Paste-on-select

    /// Writes the item back to the system pasteboard and records the resulting changeCount
    /// so the monitor knows not to re-capture it.
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text(let s):
            pb.setString(s, forType: .string)

        case .image(let payload):
            if let tiff = payload.image.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }

        case .files(let payload):
            let urls = payload.files.compactMap { ref -> URL? in
                var stale = false
                return try? URL(
                    resolvingBookmarkData: ref.bookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            }
            if !urls.isEmpty {
                pb.writeObjects(urls as [NSURL])
            }
        }

        lastInternalChangeCount = pb.changeCount
    }

    // MARK: - Auto-purge

    private func scheduleAutoPurge() {
        purgeTimer?.invalidate()
        purgeTimer = nil

        guard let interval = settings.autoClearInterval.seconds else { return }

        // Check once a minute so the granularity is fine enough for an "1 hour" setting.
        let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.purgeOlder(than: interval)
        }
        RunLoop.main.add(tick, forMode: .common)
        purgeTimer = tick

        // Catch up immediately when interval shortens.
        purgeOlder(than: interval)
    }

    private func purgeOlder(than interval: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-interval)
        items.removeAll { $0.capturedAt < cutoff }
    }
}
