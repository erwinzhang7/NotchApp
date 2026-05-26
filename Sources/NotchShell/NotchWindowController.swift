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
///
/// AMBIENT REFLOW
/// The expanded panel's HEIGHT depends on whether the ambient dashboard's
/// bottom row (Calendar / Reminders) is showing. We observe AmbientSettings;
/// when either toggle flips, the expanded size is recomputed, the
/// NotchLayoutModel publishes the new size (SwiftUI reflows the content),
/// and the panel frame animates to match.
@MainActor
final class NotchWindowController: NSObject {
    private let state = NotchState()
    private let ambient = AmbientSettings.shared
    private let layoutModel: NotchLayoutModel
    private var panel: NotchPanel?
    private var collapsedPanelFrame: CGRect = .zero
    private var expandedPanelFrame: CGRect = .zero
    private var screenObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var mouseMovedMonitor: EventMonitor?
    private var cancellables = Set<AnyCancellable>()

    /// Compact music-view height inside the dashboard. Must stay in sync
    /// with AmbientDashboardView.musicHeight.
    private static let ambientMusicHeight: CGFloat = 160
    /// Additional height contributed by the bottom row (Calendar / Reminders)
    /// when at least one of them is enabled. Sized for a few events plus a
    /// short scrollable reminder list — at-a-glance, not dense.
    private static let ambientBottomHeight: CGFloat = 200

    override init() {
        // Bootstrap with sane defaults; show() refreshes from actual screen.
        self.layoutModel = NotchLayoutModel(
            collapsedSize: NotchGeometry.fallbackCollapsedSize,
            expandedSize: NotchGeometry.defaultExpandedSize
        )
        super.init()
    }

    func show() {
        let initialExpanded = computeExpandedSize()
        guard let placement = NotchGeometry.placement(expandedSize: initialExpanded) else { return }

        layoutModel.expandedSize = placement.expandedSize
        expandedPanelFrame = placement.panelFrame
        collapsedPanelFrame = pillFrame(for: placement)

        // Create the panel at the exact frame it should appear at, so the
        // first paint lands at the centered collapsed position rather than
        // the contentRect-derived expanded frame (which produced a brief
        // off-center slide on launch).
        let initialFrame = state.isExpanded ? expandedPanelFrame : collapsedPanelFrame
        let panel = NotchPanel(contentRect: initialFrame)
        // FirstMouseHostingView overrides acceptsFirstMouse so clicks on
        // SwiftUI rows register on the first click even when the panel
        // isn't key — without this, the first click on a Clip row gets
        // consumed activating the non-activating panel and the tap never
        // fires (right-click works because context menus take a different
        // event path).
        let hosting = FirstMouseHostingView(rootView: NotchShellView(
            state: state,
            layout: layoutModel
        ))
        hosting.frame = NSRect(origin: .zero, size: initialFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.orderFrontRegardless()
        self.panel = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Observer block isn't @MainActor-typed but we registered it
            // on the main queue, so this is safe.
            MainActor.assumeIsolated {
                self?.reposition()
            }
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
                // Animate the window resize in lockstep with the SwiftUI
                // panel-shape resize so they grow/shrink together. Same
                // duration and easing as NotchShellView's `.animation(...)`
                // on isExpanded — keeps the window frame and the SwiftUI
                // content edge-locked at every animation tick, so no
                // transparent gap appears above or below the panel as it
                // expands or collapses.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            }
            .store(in: &cancellables)

        // Observe ambient toggles. When either flips, recompute the expanded
        // size, push it into the layout model (SwiftUI reflows the dashboard),
        // and animate the NSPanel frame to match. Same scheduler hop as above
        // so we never run inside a layout pass.
        ambient.$showCalendar
            .combineLatest(ambient.$showReminders)
            .removeDuplicates(by: ==)
            .dropFirst()  // initial value already applied above via show()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAmbientReflow()
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
        let expanded = computeExpandedSize()
        guard let placement = NotchGeometry.placement(expandedSize: expanded) else { return }
        layoutModel.expandedSize = placement.expandedSize
        expandedPanelFrame = placement.panelFrame
        collapsedPanelFrame = pillFrame(for: placement)
        guard let panel else { return }
        panel.setFrame(state.isExpanded ? expandedPanelFrame : collapsedPanelFrame, display: true)
    }

    /// Recompute the expanded panel size from current ambient settings and
    /// resize. When collapsed: just stash the new size for next expand.
    /// When expanded: animate to the new frame in step with the SwiftUI
    /// reflow inside (same easeInOut, same duration).
    private func applyAmbientReflow() {
        let expanded = computeExpandedSize()
        guard let placement = NotchGeometry.placement(expandedSize: expanded) else { return }
        layoutModel.expandedSize = placement.expandedSize
        expandedPanelFrame = placement.panelFrame
        // collapsedPanelFrame doesn't depend on expanded size — pill width is
        // driven by the collapsed notch dimensions, unchanged here.
        guard state.isExpanded, let panel = panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(expandedPanelFrame, display: true)
        }
    }

    /// Expanded panel size as a function of ambient settings. Same height
    /// for both tabs — Clip adapts to whatever height Ambient asks for
    /// (compact one-file + bare list when music-only; full search + strip
    /// when there's a bottom row).
    ///
    /// The tab strip sits inside the expanded panel at the notch's height,
    /// so we include `collapsedSize.height` here too. Without it the panel
    /// was 38pt short and the tab strip slid up over the fixed-height
    /// music view.
    private func computeExpandedSize() -> CGSize {
        let width = NotchGeometry.defaultExpandedSize.width
        let hasBottom = ambient.showCalendar || ambient.showReminders
        let tabStrip = layoutModel.collapsedSize.height
        let height = tabStrip
            + Self.ambientMusicHeight
            + (hasBottom ? Self.ambientBottomHeight : 0)
        return CGSize(width: width, height: height)
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
    ///
    /// We can't use CGRect.contains directly: it treats the top/right edges as
    /// exclusive, and macOS pins the cursor's y to screen.maxY when the user
    /// shoves it against the menu bar edge — same value as zone.maxY, so the
    /// very top row would never read as in-zone.
    private func handleMouseMoved() {
        let p = NSEvent.mouseLocation
        let zone = state.isExpanded ? expandedPanelFrame : collapsedPanelFrame
        let inZone = p.x >= zone.minX && p.x <= zone.maxX
                  && p.y >= zone.minY && p.y <= zone.maxY
        state.setHovered(inZone)
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
