import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Global mouse monitor that detects when a drag started in another app
/// (Finder, Safari, etc.) crosses a designated screen region — before the
/// drag enters any of our NSWindows. Lets the notch panel pre-expand to
/// "greet" the drag instead of waiting until the cursor crosses into the
/// small collapsed pill.
///
/// Pattern lifted from boring.notch's `DragDetector.swift`. Key trick:
/// `NSEvent.addGlobalMonitorForEvents` only fires while the cursor is over
/// OTHER apps' windows, which is exactly what we want — we don't need to
/// know about drags that originate or land inside our own panel (SwiftUI's
/// `.onDrop` already covers that case).
///
/// Validity check: the system writes the drag payload to the `.drag`
/// pasteboard once the user starts moving. We sample `changeCount` at
/// mouse-down and watch for it to bump on the first dragged event, then
/// confirm the new types include something we care about (file URL, web
/// URL, plain text).
@MainActor
final class DragDetector {
    /// Callback site for the current notch hot region in screen
    /// coordinates. Re-queried on every dragged event so it stays
    /// accurate as activities widen the pill, the user moves the notch
    /// to another display, etc.
    var notchRegion: () -> CGRect = { .zero }

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var downMonitor: Any?
    private var draggedMonitor: Any?
    private var upMonitor: Any?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var pasteboardBaseline: Int = -1
    private var isDragging = false
    private var hasValidContent = false
    private var isInRegion = false

    /// Pasteboard types we consider "shelf-droppable". Mirrors the cascade
    /// in `FileShelfStore.accept`. Plain text included so even free-form
    /// selections from a browser pre-expand the panel.
    private static let acceptedTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType(UTType.url.identifier),
        .string
    ]

    func start() {
        guard downMonitor == nil else { return }

        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pasteboardBaseline = self.dragPasteboard.changeCount
                self.isDragging = true
                self.hasValidContent = false
                self.isInRegion = false
            }
        }

        draggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleDragged() }
        }

        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleUp() }
        }
    }

    func stop() {
        for m in [downMonitor, draggedMonitor, upMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        downMonitor = nil
        draggedMonitor = nil
        upMonitor = nil
        if isInRegion { onExit?() }
        isInRegion = false
        isDragging = false
        hasValidContent = false
    }

    private func handleDragged() {
        guard isDragging else { return }

        // Validity is sticky: once the pasteboard has bumped AND the new
        // types include something we care about, we don't re-check. The
        // dragging session keeps the payload on the .drag pasteboard until
        // mouseUp.
        if !hasValidContent {
            let bumped = dragPasteboard.changeCount != pasteboardBaseline
            if bumped, hasAcceptedType() {
                hasValidContent = true
            }
        }
        guard hasValidContent else { return }

        let p = NSEvent.mouseLocation
        let region = notchRegion()
        let inside = region.contains(p)
        if inside != isInRegion {
            isInRegion = inside
            if inside { onEnter?() } else { onExit?() }
        }
    }

    private func handleUp() {
        if isInRegion { onExit?() }
        isInRegion = false
        isDragging = false
        hasValidContent = false
    }

    private func hasAcceptedType() -> Bool {
        guard let types = dragPasteboard.types else { return false }
        return types.contains(where: Self.acceptedTypes.contains)
    }
}
