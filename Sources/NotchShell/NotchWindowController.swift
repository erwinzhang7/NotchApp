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
    /// Exposed so peripheral panels (e.g. IdleNotchPillController) can
    /// observe expansion to coordinate their own visibility.
    let state = NotchState()
    private let ambient = AmbientSettings.shared
    private let layoutModel: NotchLayoutModel
    private var panel: NotchPanel?
    private var collapsedPanelFrame: CGRect = .zero
    private var expandedPanelFrame: CGRect = .zero
    private var screenObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var mouseMovedMonitor: EventMonitor?
    private var cancellables = Set<AnyCancellable>()
    /// Current visible size of the idle pill (base + any active activity
    /// extension). Drives the collapsed hover zone so the hot rect matches
    /// the rendered pill exactly — including the wider footprint when an
    /// activity like NowPlaying is on screen. Updated from the activity
    /// engine after `bindActivityEngine`.
    private var currentVisibleSize: CGSize = .zero

    /// Compact music-view height inside the dashboard. Must stay in sync
    /// with AmbientDashboardView.musicHeight.
    private static let ambientMusicHeight: CGFloat = 160
    /// Additional height contributed by the bottom row (Calendar / Reminders)
    /// when at least one of them is enabled. Sized for a few events plus a
    /// short scrollable reminder list — at-a-glance, not dense.
    private static let ambientBottomHeight: CGFloat = 200
    private static let tokenUsageHeight: CGFloat = 60

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

        // Panel is always at the expanded frame — we do NOT resize the
        // window on expand/collapse. SwiftUI animates the visible
        // content's size inside the fixed window with a pure spring,
        // which is the only way to get the silky open/close feel
        // (matching Atoll's approach). When the panel is collapsed
        // mouse events are passed through via `ignoresMouseEvents`
        // so clicks in the now-transparent expanded area reach apps
        // beneath.
        let panel = NotchPanel(contentRect: expandedPanelFrame)
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
        hosting.frame = NSRect(origin: .zero, size: expandedPanelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.ignoresMouseEvents = !state.isExpanded

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
                // The window stays at expandedPanelFrame size always; the
                // SwiftUI content animates the visible region inside it
                // with a pure spring. We only toggle mouse-event
                // passthrough so the now-transparent expanded area lets
                // clicks reach apps below while collapsed.
                panel.ignoresMouseEvents = !isExpanded
            }
            .store(in: &cancellables)

        // Observe ambient toggles. When any layout-affecting switch flips, recompute the expanded
        // size, push it into the layout model (SwiftUI reflows the dashboard),
        // and animate the NSPanel frame to match. Same scheduler hop as above
        // so we never run inside a layout pass.
        ambient.$showCalendar
            .combineLatest(ambient.$showReminders, ambient.$showTokenUsage)
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 }
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
            + (ambient.showTokenUsage ? Self.tokenUsageHeight : 0)
        return CGSize(width: width, height: height)
    }

    /// Collapsed pill footprint in screen coordinates: just big enough to cover
    /// the visible pill plus hover slop, top-aligned with the expanded frame.
    /// When an activity widens the idle pill (e.g. NowPlaying), the hot zone
    /// tracks that wider footprint so hover/drag-to-reveal land on the entire
    /// rendered surface.
    private func pillFrame(for placement: NotchGeometry.Placement) -> CGRect {
        let slop = NotchGeometry.hoverSlop
        let visibleWidth = max(placement.collapsedSize.width, currentVisibleSize.width)
        let visibleHeight = max(placement.collapsedSize.height, currentVisibleSize.height)
        let w = visibleWidth + slop * 2
        let h = visibleHeight + slop
        return CGRect(
            x: placement.panelFrame.midX - w / 2,
            y: placement.panelFrame.maxY - h,
            width: w,
            height: h
        )
    }

    /// Wire the activity engine so the collapsed hot zone follows the
    /// current visible pill size. Called from AppDelegate after both the
    /// shell and the idle pill have started. Idempotent — re-binding
    /// replaces the prior subscription.
    func bindActivityEngine(_ engine: NotchActivityEngine) {
        currentVisibleSize = engine.model.size
        refreshCollapsedFrame()
        engine.$model
            .map(\.size)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                guard let self else { return }
                self.currentVisibleSize = size
                self.refreshCollapsedFrame()
            }
            .store(in: &cancellables)
    }

    private func refreshCollapsedFrame() {
        guard let placement = NotchGeometry.placement(expandedSize: layoutModel.expandedSize) else { return }
        collapsedPanelFrame = pillFrame(for: placement)
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
