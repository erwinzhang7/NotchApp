import AppKit
import Combine
import SwiftUI

/// A small, centered, music-only widget that uses SkyLight private API
/// to render above the lock-screen layer. Visibility policy:
///   - locked → show
///   - unlocked, system idle → show
///   - unlocked, user active → hide
///
/// Disabled by default; opt-in from Settings. When disabled, the
/// controller doesn't load SkyLight or create the panel.
@MainActor
final class LockScreenMusicWidgetController {
    private let lockObserver = LockScreenObserver()
    private let idleMonitor = IdleMonitor()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeObserver: NSObjectProtocol?

    private var locked = false
    private var idle = false

    private var ambient: AmbientSettings { AmbientSettings.shared }

    /// Panel dimensions, tuned to fit artwork + title/artist + scrubber +
    /// transport buttons with a comfortable margin.
    private static let panelSize = NSSize(width: 320, height: 460)

    // MARK: - Lifecycle

    func start() {
        applyEnabled()
        ambient.$lockScreenWidgetEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyEnabled() }
            .store(in: &cancellables)
        ambient.$lockScreenWidgetIdleTimeoutSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] secs in
                self?.idleMonitor.threshold = TimeInterval(secs)
            }
            .store(in: &cancellables)
    }

    func stop() {
        teardown()
    }

    /// Build or tear down all observers + window based on the master toggle.
    private func applyEnabled() {
        if ambient.lockScreenWidgetEnabled {
            buildIfNeeded()
            installObservers()
            refreshVisibility()
        } else {
            teardown()
        }
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let p = makePanel()
        panel = p
        // Hand the panel to SkyLight so it sits in the
        // notification-center-at-screen-lock space. Done once at creation
        // — the space membership persists for the panel's lifetime.
        if SkyLightSpace.shared.isAvailable {
            SkyLightSpace.shared.assign(p)
        }
    }

    private func installObservers() {
        lockObserver.onLocked = { [weak self] in self?.locked = true; self?.refreshVisibility() }
        lockObserver.onUnlocked = { [weak self] in self?.locked = false; self?.refreshVisibility() }
        lockObserver.onScreensaverStart = { [weak self] in self?.locked = true; self?.refreshVisibility() }
        lockObserver.onScreensaverStop = { [weak self] in self?.locked = false; self?.refreshVisibility() }
        lockObserver.start()

        idleMonitor.threshold = TimeInterval(ambient.lockScreenWidgetIdleTimeoutSeconds)
        idleMonitor.onIdle = { [weak self] in self?.idle = true; self?.refreshVisibility() }
        idleMonitor.onActive = { [weak self] in self?.idle = false; self?.refreshVisibility() }
        idleMonitor.start()

        // Re-center on display config changes (resolution shift, monitor
        // unplugged, etc.) so the widget doesn't end up off-screen.
        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.recenter() }
            }
        }
    }

    private func teardown() {
        lockObserver.stop()
        idleMonitor.stop()
        panel?.orderOut(nil)
        panel = nil
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
    }

    /// Move the panel back to the screen's center. Called when the
    /// display geometry changes.
    private func recenter() {
        guard let panel, let screen = NSScreen.main?.frame else { return }
        let size = Self.panelSize
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func refreshVisibility() {
        guard let panel else { return }
        let shouldShow = locked || idle
        if shouldShow, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let size = Self.panelSize
        // Center on the main screen at launch; SkyLight space pins it
        // there across spaces.
        let screen = NSScreen.main?.frame ?? .zero
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )
        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        // Let the NSPanel draw the drop shadow itself — when the
        // contentView is layer-backed with a rounded corner, the system
        // shadow follows that rounded shape exactly. SwiftUI's .shadow
        // around an AppKit-backed background was rendering the bounding
        // rectangle, which read as the visible outer rect.
        p.hasShadow = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        // Required so scrubber-drag and transport-button clicks register
        // (was false because the original card was display-only).
        p.acceptsMouseMovedEvents = true
        // Both are critical for the lock-screen path:
        //   - canBecomeVisibleWithoutLogin → window-server keeps the
        //     window around even when no user session "owns" the screen
        //   - collectionBehavior covers spaces / fullscreen edge cases so
        //     the window doesn't disappear when other apps go fullscreen
        p.canBecomeVisibleWithoutLogin = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.level = .mainMenu + 1

        let root = LockScreenMusicCardView(
            state: MediaControls.shared.state,
            adapter: MediaControls.shared.adapter
        )
        // FirstMouseHostingView lets clicks register on the first hit even
        // when the panel isn't key — same fix used for the Clip rows.
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // Round the hosting view at the layer level so any AppKit-drawn
        // chrome (background colors, the panel shadow) follows the same
        // shape as the SwiftUI card — eliminates the "outer rect" that
        // SwiftUI's clipShape can't reach.
        host.wantsLayer = true
        host.layer?.cornerCurve = .continuous
        host.layer?.cornerRadius = 24
        host.layer?.masksToBounds = true
        p.contentView = host
        return p
    }
}
