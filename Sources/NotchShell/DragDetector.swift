import AppKit
import Foundation
import UniformTypeIdentifiers

/// Global mouse monitor that fires `onEnter` when the cursor — while
/// carrying a drag payload with shelf-acceptable types — crosses into the
/// notch hot region, and `onExit` when it leaves or the drag ends. Lets
/// the notch panel pre-expand to "greet" drags from other apps before
/// SwiftUI's `.onDrop` would see them.
///
/// Implementation: rather than tracking a mouseDown→Dragged→Up state
/// machine (whose `.leftMouseDragged` events may or may not fire reliably
/// during a system drag-tracking session, depending on macOS version),
/// just sample on every `.mouseMoved` AND `.leftMouseDragged` global
/// event. The `.drag` pasteboard's `types` array is the source of truth
/// for "is a drag in progress with content we care about" — it's populated
/// for the duration of a drag session and cleared between sessions, so a
/// per-event check is sufficient.
@MainActor
final class DragDetector {
    /// Callback site for the current notch hot region in screen
    /// coordinates. Re-queried on every event so it tracks activity-
    /// widened pill sizes and screen changes.
    var notchRegion: () -> CGRect = { .zero }

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var monitors: [Any] = []
    private var isInRegion = false

    private let dragPasteboard = NSPasteboard(name: .drag)

    /// Pasteboard types we consider "shelf-droppable". Mirrors the cascade
    /// in `FileShelfStore.accept`.
    private static let acceptedTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType(UTType.url.identifier),
        .string
    ]

    func start() {
        guard monitors.isEmpty else { return }
        // Both .mouseMoved and .leftMouseDragged: during a drag session
        // some macOS versions only post one or the other to global
        // monitors. Listening to both is harmless — `update()` is idempotent.
        for mask: NSEvent.EventTypeMask in [.mouseMoved, .leftMouseDragged, .leftMouseUp] {
            let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.update() }
            })
            if let m { monitors.append(m) }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if isInRegion {
            onExit?()
            isInRegion = false
        }
    }

    private func update() {
        // A drag is "live" iff the .drag pasteboard currently exposes a
        // type we accept. Between sessions, types is nil/empty.
        let valid = hasAcceptedType()
        let inside: Bool
        if valid {
            inside = notchRegion().contains(NSEvent.mouseLocation)
        } else {
            inside = false
        }
        guard inside != isInRegion else { return }
        isInRegion = inside
        if inside { onEnter?() } else { onExit?() }
    }

    private func hasAcceptedType() -> Bool {
        guard let types = dragPasteboard.types, !types.isEmpty else { return false }
        return types.contains(where: Self.acceptedTypes.contains)
    }
}
