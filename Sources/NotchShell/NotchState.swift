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

    /// Currently selected tab. Mirrored from NotchShellView's @AppStorage so
    /// NotchWindowController can re-size the panel on tab change (Clip needs
    /// more vertical room than music-only Ambient).
    @Published var selectedTab: NotchTab = NotchTab(rawValue: UserDefaults.standard.string(forKey: "notch.selectedTab") ?? "") ?? .ambient

    /// The shell is expanded if anything is keeping it open: hover, explicit pin, the
    /// post-paste hold, or an active drag-and-drop targeting the panel.
    var isExpanded: Bool { isHovered || isPinned || isHeldOpen || isDragTargeted }

    // Open-intent delay: cursor must dwell on the notch this long before the panel
    // expands. Stops quick swipes past the notch from flashing the panel open.
    private let openDelay: Duration = .milliseconds(100)
    // Close grace: cursor can briefly leave the hit region without triggering collapse.
    private let collapseDelay: Duration = .milliseconds(150)
    private var hoverDebounce: Task<Void, Never>?
    private var holdOpenTask: Task<Void, Never>?

    func setHovered(_ hovering: Bool) {
        // Always cancel the in-flight debounce — whatever transition was pending is
        // superseded by the new target. If the new target matches current state, we
        // also cancel any scheduled change in the OTHER direction (e.g. cursor returns
        // during the close grace) and stay put.
        hoverDebounce?.cancel()
        if hovering == isHovered { return }
        let delay = hovering ? openDelay : collapseDelay
        hoverDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isHovered = hovering
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
