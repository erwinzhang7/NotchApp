import AppKit
import Combine
import SwiftUI

/// Always-visible Dynamic-Island-style pill that hugs the physical notch.
/// Hosts the `NotchActivityEngine` so activities (brightness, volume,
/// charging, bluetooth connect, now-playing) appear in the same surface.
///
/// Lives in its own NSPanel so it can sit above wallpaper and most windows
/// at all times without interfering with `NotchWindowController`'s expanded
/// shell panel (which uses the swept-corner `NotchPanelShape`).
///
/// Visibility rules:
/// - Always visible at rest.
/// - Hidden while the main shell panel is expanded (hover / pin / drag /
///   held-open) so the inward shape doesn't show up behind the swept-corner
///   expanded chrome.
/// - Hidden while the lock-screen presentation owns the screen so the
///   lock-notch indicator (different shape, different layer) can take over.
@MainActor
final class IdleNotchPillController {
    /// Extra width past the physical notch at rest. Zero — user wants
    /// the idle pill flush with the notch, no wasted real estate.
    /// Activities extend from here on demand.
    private static let widthExtension: CGFloat = 0
    /// Maximum extra width an activity can add per side. Drives the
    /// (fixed) NSPanel frame width — activities animate inside it, the
    /// window itself doesn't resize. Sized for the widest activity
    /// (bluetooth at ~170pt leading + 90pt trailing).
    private static let maxActivityExtraWidth: CGFloat = 200
    /// Flush with the physical notch height — no activity grows
    /// vertically (lyrics live in the expanded shell, not the pill;
    /// the copy banner lives in its own panel below the notch).
    private static let heightExtension: CGFloat = 0

    private let shellState: NotchState
    private let lockObserver: LockScreenObserver
    private let fullscreenObserver: FullscreenSpaceObserver
    let engine = NotchActivityEngine()
    private var panel: IdleNotchPanel?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var physicalNotchSize: CGSize = .zero

    init(
        shellState: NotchState,
        lockObserver: LockScreenObserver,
        fullscreenObserver: FullscreenSpaceObserver
    ) {
        self.shellState = shellState
        self.lockObserver = lockObserver
        self.fullscreenObserver = fullscreenObserver
    }

    func start() {
        buildPanelIfNeeded()
        refreshVisibility()

        shellState.$isHovered
            .combineLatest(shellState.$isPinned, shellState.$isHeldOpen, shellState.$isDragTargeted)
            .map { h, p, o, d in h || p || o || d }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        lockObserver.$isLocked
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        fullscreenObserver.$fullscreenDisplays
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
    }

    func stop() {
        cancellables.removeAll()
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private var shouldShow: Bool {
        if shellState.isExpanded { return false }
        if lockObserver.isLocked { return false }
        // Hide on a display whose current space is macOS-fullscreen (e.g.
        // YouTube / Netflix / Quick Time green-buttoned). Falling back to
        // the placement screen's UUID keeps us correct when the user has
        // moved the notch to an external display.
        if let uuid = NotchGeometry.placement()?.screen.displayUUID,
           fullscreenObserver.fullscreenDisplays.contains(uuid) {
            return false
        }
        return true
    }

    private func refreshVisibility() {
        guard let panel else { return }
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func reposition() {
        guard let panel, let frame = idleFrame() else { return }
        panel.setFrame(frame, display: true)
    }

    private func buildPanelIfNeeded() {
        guard panel == nil, let frame = idleFrame(), let notchSize = currentNotchSize() else { return }
        physicalNotchSize = notchSize

        // One-shot console line so we always know what the system is
        // actually reporting for the camera area on this Mac. Width
        // comes from `screen.frame.width - auxiliaryTopLeftArea.width
        // - auxiliaryTopRightArea.width`; height from
        // `screen.safeAreaInsets.top`.
        NSLog("[IdleNotchPill] measured notch: width=%.1fpt height=%.1fpt",
              notchSize.width, notchSize.height)

        let baseSize = CGSize(
            width: notchSize.width + Self.widthExtension * 2,
            height: notchSize.height + Self.heightExtension
        )
        engine.updateBaseSize(baseSize)

        let p = IdleNotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        // Display-only — mouse passes through so the existing
        // NotchWindowController hover detection still drives expand /
        // collapse from the same area, and so app windows / menu-bar
        // items under the panel's transparent regions remain
        // interactive.
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.level = .statusBar
        p.alphaValue = 1
        p.animationBehavior = .none

        let host = NSHostingView(rootView: IdleNotchPillView(
            engine: engine,
            physicalNotchWidth: notchSize.width
        )
        .environment(\.physicalNotchWidth, notchSize.width))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host

        self.panel = p
    }

    /// Pill frame in screen coordinates. Width is fixed at "widest
    /// possible activity" so the SwiftUI shape inside can animate
    /// without the NSPanel itself resizing — same trick
    /// `NotchWindowController` uses for the expanded shell.
    private func idleFrame() -> NSRect? {
        guard let placement = NotchGeometry.placement(), placement.hasNotch else {
            return nil
        }
        let notch = placement.collapsedSize
        let width = notch.width + Self.widthExtension * 2 + Self.maxActivityExtraWidth * 2
        let height = notch.height + Self.heightExtension
        let x = placement.screen.frame.midX - width / 2
        let y = placement.screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func currentNotchSize() -> CGSize? {
        NotchGeometry.placement()?.collapsedSize
    }
}

/// NSPanel subclass that can't accidentally steal key / main from real
/// app windows.
final class IdleNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Environment value carrying the physical notch width down into
/// activity views. Lets each activity reserve a dead-zone the camera
/// width without hardcoding it. The host injects this at the root.
private struct PhysicalNotchWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Width of the hardware notch in points. Activity views use this
    /// to lay leading + trailing content in the wings on either side
    /// of the camera, leaving the middle column visually clear.
    var physicalNotchWidth: CGFloat {
        get { self[PhysicalNotchWidthKey.self] }
        set { self[PhysicalNotchWidthKey.self] = newValue }
    }
}

private struct IdleNotchPillView: View {
    @ObservedObject var engine: NotchActivityEngine
    let physicalNotchWidth: CGFloat

    var body: some View {
        // Top-aligned inside the NSPanel frame: the shape grows downward
        // from the screen top so the notch stays anchored visually.
        // The Spacer below the pill carries `allowsHitTesting(false)`
        // so clicks in the empty area beneath the pill pass through
        // to whatever's behind (menu bar, wallpaper) instead of being
        // captured by the panel.
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .top)
    }

    private var pill: some View {
        let size = engine.model.size
        let baseRadius = min(size.height, 32) / 3
        let topRadius = max(0, baseRadius - 4)
        let bottomRadius = baseRadius

        return ZStack {
            // Background shape — never hit-testable so it doesn't eat
            // clicks meant for whatever's behind the inward curves.
            InwardNotchShape(
                topCornerRadius: topRadius,
                bottomCornerRadius: bottomRadius
            )
            .fill(Color.black)
            .allowsHitTesting(false)

            if let activity = engine.model.current {
                activity.makeView()
                    .id(activity.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .clipShape(
                        InwardNotchShape(
                            topCornerRadius: topRadius,
                            bottomCornerRadius: bottomRadius
                        )
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(NotchAnimations.contentUpdate, value: size)
        .animation(NotchAnimations.contentShow, value: engine.model.current?.id)
    }
}
