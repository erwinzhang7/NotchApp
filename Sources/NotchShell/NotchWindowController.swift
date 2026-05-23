import AppKit
import Combine
import SwiftUI

/// Owns the notch panel and the interaction state.
///
/// HOVER DETECTION (NotchDrop pattern)
/// SwiftUI .onHover fires inside the SwiftUI layout pass; calling setFrame from
/// inside that pass triggers AppKit's layout-recursion guard ("not legal to call
/// -layoutSubtreeIfNeeded..."). To break that cycle, hover is detected by a
/// global NSEvent monitor on .mouseMoved — the cursor's screen position is
/// compared against the current hot zone (pill rect when collapsed, expanded
/// rect when open) and pushed into NotchState.setHovered.
///
/// Global monitors only fire while the cursor is over OTHER apps' windows;
/// once it crosses into our panel, no further events arrive until it exits,
/// which is fine — we just want to know about entry and exit.
///
/// CLICK-THROUGH
/// The panel's window frame shrinks to the pill footprint while collapsed
/// (no large invisible window above the rest of the screen, so the OS routes
/// clicks straight to the apps below). The frame change is deferred one main
/// queue cycle so it never fires inside a SwiftUI layout pass.
final class NotchWindowController: NSObject {
    private let state = NotchState()
    private var panel: NotchPanel?
    private var collapsedPanelFrame: CGRect = .zero
    private var expandedPanelFrame: CGRect = .zero
    private var screenObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var mouseMovedMonitor: EventMonitor?
    private var cancellables = Set<AnyCancellable>()

    func show() {
        guard let placement = NotchGeometry.placement() else { return }

        expandedPanelFrame = placement.panelFrame
        collapsedPanelFrame = pillFrame(for: placement)

        let panel = NotchPanel(contentRect: placement.panelFrame)
        let hosting = NSHostingView(rootView: NotchShellView(
            state: state,
            collapsedSize: placement.collapsedSize,
            expandedSize: placement.expandedSize
        ))
        hosting.frame = NSRect(origin: .zero, size: placement.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // Start at the correct size before showing so the panel never flashes at
        // expanded size on launch.
        panel.setFrame(state.isExpanded ? expandedPanelFrame : collapsedPanelFrame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }

        state.$isPinned
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                if pinned {
                    self?.startGlobalClickMonitor()
                } else {
                    self?.stopGlobalClickMonitor()
                }
            }
            .store(in: &cancellables)

        // Resize the panel in response to expand/collapse state. Deferred to the
        // next main queue cycle so the setFrame call cannot fire inside a SwiftUI
        // layout pass (that's what produces the "not legal to call
        // -layoutSubtreeIfNeeded on a view which is already being laid out"
        // warning and silently drops the resize). The deferral only delays
        // delivery — combineLatest snapshots the value at emission time, so
        // there is no stale-read window.
        state.$isHovered
            .combineLatest(state.$isPinned, state.$isHeldOpen, state.$isDragTargeted)
            .map { h, p, o, d in h || p || o || d }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isExpanded in
                guard let self, let panel = self.panel else { return }
                let target = isExpanded ? self.expandedPanelFrame : self.collapsedPanelFrame
                if isExpanded {
                    panel.setFrame(target, display: true)
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.4
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().setFrame(target, display: true)
                    }
                }
            }
            .store(in: &cancellables)

        let monitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
        monitor.start()
        mouseMovedMonitor = monitor
    }

    func hide() {
        stopGlobalClickMonitor()
        mouseMovedMonitor?.stop()
        mouseMovedMonitor = nil
        cancellables.removeAll()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func reposition() {
        guard let placement = NotchGeometry.placement() else { return }
        expandedPanelFrame = placement.panelFrame
        collapsedPanelFrame = pillFrame(for: placement)
        guard let panel else { return }
        panel.setFrame(state.isExpanded ? expandedPanelFrame : collapsedPanelFrame, display: true)
    }

    /// Collapsed pill footprint in screen coordinates: just big enough to cover
    /// the visible pill plus hover slop, top-aligned with the expanded frame.
    private func pillFrame(for placement: NotchGeometry.Placement) -> CGRect {
        let slop = NotchGeometry.hoverSlop
        let w = placement.collapsedSize.width + slop * 2
        let h = placement.collapsedSize.height + slop
        return CGRect(
            x: placement.panelFrame.midX - w / 2,
            y: placement.panelFrame.maxY - h,
            width: w,
            height: h
        )
    }

    /// Compute hover state from cursor position. When collapsed, the hot zone is
    /// the small pill rect at the notch; when expanded, it's the full expanded
    /// frame. This runs from the global mouse-moved monitor, which only fires
    /// while the cursor is over other apps — so transitions across the panel
    /// boundary are detected, but movement inside the panel doesn't churn.
    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        let zone = state.isExpanded ? expandedPanelFrame : collapsedPanelFrame
        state.setHovered(zone.contains(mouseLocation))
    }

    private func startGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.state.unpin()
        }
    }

    private func stopGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
