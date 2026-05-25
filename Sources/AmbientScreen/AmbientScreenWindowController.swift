import AppKit
import Combine
import SwiftUI

/// Owns the full-screen ambient window and wires its three triggers:
/// auto-on-idle (IdleMonitor), global hotkey (AmbientHotkey), and manual
/// (statusbar menu / public toggle()). Suppressed while the system
/// lockscreen / screensaver owns the display so we don't fight with them.
@MainActor
final class AmbientScreenWindowController: NSObject {
    private var window: NSWindow?
    private let idleMonitor = IdleMonitor()
    private let lockObserver = LockScreenObserver()
    private var hotkey: AmbientHotkey?
    private var activityMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// True while the system screensaver / lockscreen is showing. We
    /// keep ourselves hidden in this case (won't display on top anyway).
    private var systemSurfaceActive = false

    /// True if we were showing when something suppressed us — used to
    /// restore on unlock.
    private var restoreAfterLock = false

    private var ambient: AmbientSettings { AmbientSettings.shared }

    // MARK: - Lifecycle

    func start() {
        installLockObserver()
        installHotkey()
        configureIdleMonitor()

        // Re-wire when prefs change (idle threshold, master enable).
        ambient.$ambientScreenEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureIdleMonitor() }
            .store(in: &cancellables)
        ambient.$ambientScreenTriggerOnIdle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureIdleMonitor() }
            .store(in: &cancellables)
        ambient.$ambientScreenIdleTimeoutSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] secs in
                self?.idleMonitor.threshold = TimeInterval(secs)
            }
            .store(in: &cancellables)
    }

    func stop() {
        idleMonitor.stop()
        lockObserver.stop()
        hotkey = nil
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
        hide()
    }

    // MARK: - Triggers

    private func installLockObserver() {
        lockObserver.onLocked = { [weak self] in
            self?.systemSurfaceActive = true
            self?.hideForSystemSurface()
        }
        lockObserver.onUnlocked = { [weak self] in
            self?.systemSurfaceActive = false
            self?.restoreAfterSystemSurfaceIfNeeded()
        }
        lockObserver.onScreensaverStart = { [weak self] in
            self?.systemSurfaceActive = true
            self?.hideForSystemSurface()
        }
        lockObserver.onScreensaverStop = { [weak self] in
            self?.systemSurfaceActive = false
            self?.restoreAfterSystemSurfaceIfNeeded()
        }
        lockObserver.start()
    }

    private func installHotkey() {
        let hk = AmbientHotkey()
        hk.onFire = { [weak self] in self?.toggle() }
        self.hotkey = hk
    }

    private func configureIdleMonitor() {
        idleMonitor.stop()
        guard ambient.ambientScreenEnabled, ambient.ambientScreenTriggerOnIdle else {
            return
        }
        idleMonitor.threshold = TimeInterval(ambient.ambientScreenIdleTimeoutSeconds)
        idleMonitor.onIdle = { [weak self] in
            guard let self else { return }
            // Don't show if the system surface owns the display — we'd
            // be invisible anyway.
            if self.systemSurfaceActive { return }
            self.show()
        }
        idleMonitor.onActive = { [weak self] in
            guard let self else { return }
            if self.ambient.ambientScreenDismissOnActivity {
                self.hide()
            }
        }
        idleMonitor.start()
    }

    // MARK: - Window

    /// Toggle from anywhere (menu item, hotkey).
    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard ambient.ambientScreenEnabled else { return }
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }

        if let screen = NSScreen.main {
            window.setFrame(screen.frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        installActivityMonitorIfNeeded()
    }

    func hide() {
        window?.orderOut(nil)
        removeActivityMonitor()
    }

    private func hideForSystemSurface() {
        if window?.isVisible == true {
            restoreAfterLock = true
            hide()
        }
    }

    private func restoreAfterSystemSurfaceIfNeeded() {
        guard restoreAfterLock else { return }
        restoreAfterLock = false
        // Only restore if the user is still effectively idle — otherwise
        // they've unlocked and started working, no need to nag them.
        if IdleMonitor.systemIdleSeconds() >= TimeInterval(ambient.ambientScreenIdleTimeoutSeconds) {
            show()
        }
    }

    private func makeWindow() -> NSWindow {
        let initialFrame = NSScreen.main?.frame ?? .zero
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false

        let root = AmbientScreenView(onDismiss: { [weak self] in self?.hide() })
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: initialFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    // MARK: - Activity tracking while visible

    /// While the ambient window is showing, listen for any mouse / key
    /// activity so we can dismiss promptly (without waiting for the next
    /// idle-poll tick to flip). Only installed while visible.
    private func installActivityMonitorIfNeeded() {
        guard activityMonitor == nil, ambient.ambientScreenDismissOnActivity else { return }
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            // Mouse-moved while the ambient window owns the cursor is
            // expected — don't auto-dismiss on cursor jiggle from showing
            // the window itself. Only dismiss on clicks / keypresses.
            if event.type != .mouseMoved {
                self?.hide()
            }
            return event
        }
    }

    private func removeActivityMonitor() {
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
    }
}
