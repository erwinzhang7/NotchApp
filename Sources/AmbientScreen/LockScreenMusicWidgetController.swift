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
    /// Small notch-shaped widget at the screen's notch position that
    /// displays the lock state. Same lifecycle as the music card.
    private var lockNotchPanel: NSPanel?
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
        ambient.$lockScreenWidgetVerticalOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recenter() }
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
        if panel == nil {
            panel = registerAndAssign(makePanel())
        }
        if lockNotchPanel == nil {
            lockNotchPanel = registerAndAssign(makeLockNotchPanel())
        }
    }

    /// Atoll's pattern: a window only gets a valid `windowNumber` after
    /// it's been ordered front at least once. SkyLight delegation needs
    /// that number. So we show-then-hide once at creation, then assign
    /// to the SkyLight space. After this any later orderFront just makes
    /// it visible at the right z-level.
    private func registerAndAssign(_ window: NSPanel) -> NSPanel {
        let prevAlpha = window.alphaValue
        window.alphaValue = 0
        window.orderFrontRegardless()
        if SkyLightSpace.shared.isAvailable, window.windowNumber > 0 {
            SkyLightSpace.shared.assign(window)
        }
        window.orderOut(nil)
        window.alphaValue = prevAlpha == 0 ? 1 : prevAlpha
        return window
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
        lockNotchPanel?.orderOut(nil)
        lockNotchPanel = nil
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
    }

    /// Reposition the panel using the current settings (vertical offset
    /// from center). Called at launch, on screen-config changes, and
    /// whenever the offset slider moves.
    private func recenter() {
        guard let panel, let screen = NSScreen.main?.frame else { return }
        let size = Self.panelSize
        panel.setFrame(
            NSRect(origin: position(on: screen, size: size), size: size),
            display: true
        )
    }

    /// Compute the panel origin. Centered horizontally; vertical position
    /// is center + the user's offset (slider: left = up, right = down).
    /// Clamps to keep the panel on-screen on shorter displays.
    private func position(on screen: NSRect, size: NSSize) -> NSPoint {
        let topMargin: CGFloat = 20

        let x = screen.midX - size.width / 2

        // Slider value: > 0 = down visually = lower Y in AppKit.
        let offset = CGFloat(ambient.lockScreenWidgetVerticalOffset)
        let desiredY = screen.midY - size.height / 2 - offset

        // Keep the panel fully on-screen.
        let maxY = screen.maxY - size.height - topMargin
        let minY = screen.minY + topMargin
        let y = min(max(desiredY, minY), maxY)
        return NSPoint(x: x, y: y)
    }

    private func refreshVisibility() {
        let shouldShow = locked || idle
        if let panel {
            if shouldShow, !panel.isVisible {
                panel.orderFrontRegardless()
            } else if !shouldShow, panel.isVisible {
                panel.orderOut(nil)
            }
        }
        if let lockNotchPanel {
            if shouldShow, !lockNotchPanel.isVisible {
                lockNotchPanel.orderFrontRegardless()
            } else if !shouldShow, lockNotchPanel.isVisible {
                lockNotchPanel.orderOut(nil)
            }
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let size = Self.panelSize
        // Position the widget per current settings (center + user offset).
        // SkyLight space pins it there across spaces.
        let screen = NSScreen.main?.frame ?? .zero
        let origin = position(on: screen, size: size)
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
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.alphaValue = 1
        p.animationBehavior = .none

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

    /// Notch-shaped indicator at the top-center of the screen (the
    /// macOS notch position) that displays the lock state with a
    /// morphing SF Symbol. Width is wider than the notch itself so the
    /// indicator zones extend to either side; the center sits exactly
    /// over the hardware notch.
    private func makeLockNotchPanel() -> NSPanel {
        // Reuse NotchGeometry's measurements so the center lines up
        // exactly with the hardware notch on notched MacBooks (or
        // falls back to a sensible pill size on non-notched displays).
        let placement = NotchGeometry.placement()
        let notchSize = placement?.collapsedSize ?? NotchGeometry.fallbackCollapsedSize
        let screen = placement?.screen.frame ?? (NSScreen.main?.frame ?? .zero)
        let indicatorSize = max(0, notchSize.height - 12)
        let totalSize = CGSize(
            width: notchSize.width + indicatorSize * 2,
            height: notchSize.height
        )
        let origin = NSPoint(
            x: screen.midX - totalSize.width / 2,
            y: screen.maxY - totalSize.height
        )

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: totalSize),
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
        // Indicator is display-only — pass mouse events through so
        // the user can still interact with whatever's underneath
        // (lock screen / desktop) at the notch position.
        p.ignoresMouseEvents = true
        p.canBecomeVisibleWithoutLogin = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // CGShieldingWindowLevel is the level macOS uses for security
        // UI (the login window / lock screen itself). Same level Atoll
        // uses for their lock-screen widget; combined with the SkyLight
        // space at NotificationCenterAtScreenLock (rank 400), this
        // guarantees the indicator renders on top of everything,
        // including the system lock screen.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.alphaValue = 1
        p.animationBehavior = .none

        let host = NSHostingView(rootView: LockNotchIndicatorView(
            lockObserver: lockObserver,
            notchSize: notchSize
        ))
        host.frame = NSRect(origin: .zero, size: totalSize)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        return p
    }
}
