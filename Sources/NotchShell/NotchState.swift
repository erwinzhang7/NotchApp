import Combine
import Foundation

/// Drives expansion of the notch surface. Three reasons can keep the panel expanded:
/// - `isHovered`: cursor is on the panel (with a 300 ms grace period after exit).
/// - `isPinned`: user explicitly pinned by clicking chrome.
/// - `isHeldOpen`: a time-bounded forced-open (e.g. so paste-on-select feedback can render).
final class NotchState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var isPinned: Bool = false
    @Published var isDragTargeted: Bool = false
    @Published private(set) var isHeldOpen: Bool = false

    /// The shell is expanded if anything is keeping it open: hover, explicit pin, the
    /// post-paste hold, or an active drag-and-drop targeting the panel.
    var isExpanded: Bool { isHovered || isPinned || isHeldOpen || isDragTargeted }

    // Grace period so the panel doesn't flicker when the cursor briefly clips the hit region.
    private let collapseDelay: Duration = .milliseconds(300)
    private var collapseTask: Task<Void, Never>?
    private var holdOpenTask: Task<Void, Never>?

    func setHovered(_ hovering: Bool) {
        collapseTask?.cancel()
        if hovering {
            isHovered = true
            return
        }
        let delay = collapseDelay
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isHovered = false
        }
    }

    func togglePinned() {
        isPinned.toggle()
    }

    func unpin() {
        isPinned = false
    }

    /// Force the panel to stay expanded for the given duration regardless of hover state.
    /// Used after paste-on-select so the in-row "Copied" feedback always has time to render
    /// even if the user's cursor has already left the panel.
    func holdOpen(for duration: Duration) {
        holdOpenTask?.cancel()
        isHeldOpen = true
        holdOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.isHeldOpen = false
        }
    }
}
