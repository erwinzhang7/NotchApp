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
    /// Exposed so peripheral panels can subscribe to the same lock state
    /// instead of spinning up their own DistributedNotificationCenter
    /// observers (cheap, but duplicating event flow is brittle).
    let lockObserver = LockScreenObserver()
    private let idleMonitor = IdleMonitor()
    /// Shared between the card view and the backdrop view so the
    /// backdrop knows when to fade its blurred-art + tint in.
    private let cardState = LockScreenMusicCardState()
    /// Background-thread blur service for the backdrop's artwork.
    /// Owned here so its lifetime tracks the widget controller and
    /// its cache survives panel hide/show cycles.
    private let blurService = LockScreenBlurService()
    private var panel: NSPanel?
    /// Full-screen blurred-art + accent-tint backdrop behind the music
    /// card. Only visually relevant while artwork is lifted; opacity
    /// inside SwiftUI gates that.
    private var backdropPanel: NSPanel?
    /// Small notch-shaped widget at the screen's notch position that
    /// displays the lock state. On unlock we hold visible briefly so
    /// the `lock.fill → lock.open.fill` symbol morph plays, then
    /// animate the panel's width down to zero (horizontal shrink from
    /// the center) before orderOut.
    private var lockNotchPanel: NSPanel?
    /// Saved full frame so we can restore the panel size for the next
    /// show after the horizontal-shrink hide.
    private var lockNotchFullFrame: NSRect = .zero
    private var lockNotchHideTask: Task<Void, Never>?
    private let lockNotchUnlockHoldDuration: TimeInterval = 0.55
    private let lockNotchShrinkDuration: TimeInterval = 0.49

    /// 0.5s timer polling CGEventSource for recent key activity.
    /// Started/stopped with the widget. Cheap (one syscall every
    /// half-second); flips `cardState.keyboardActive` when crossing
    /// the threshold so the backdrop can fade to expose the real
    /// lock-screen UI.
    private var keyboardPollTimer: Timer?
    /// Seconds since the last key-down that counts as "still typing".
    private let keyboardActiveWindow: TimeInterval = 3.0
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeObserver: NSObjectProtocol?

    private var locked = false
    private var idle = false

    private var ambient: AmbientSettings { AmbientSettings.shared }

    /// Panel dimensions for the compact card + lifted-no-lyrics layout.
    /// Tuned to fit artwork + title/artist + scrubber + transport with a
    /// comfortable margin.
    private static let compactPanelSize = NSSize(width: 480, height: 540)
    /// Wider panel for the lifted-with-lyrics layout: room for the
    /// existing left column at unchanged sizes plus a 320pt lyrics
    /// column with 24pt spacing and the card's 16pt outer padding on
    /// both sides.
    private static let lyricsPanelSize = NSSize(width: 720, height: 540)
    /// Stable consumer key the controller uses to subscribe to the
    /// lyrics service. String constant so registration is idempotent.
    private static let lyricsConsumerKey = "lockScreen"

    /// Current size — flips between compact and lyrics dimensions in
    /// response to the lift / lyrics-setting combination.
    private var currentPanelSize: NSSize = LockScreenMusicWidgetController.compactPanelSize

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

        // Lyrics-mode panel-resize: when the lifted+lyrics combination
        // becomes active, the card needs the wider panel. Re-evaluated
        // on either input changing; resize is animated for continuity
        // with the artwork-lift spring.
        ambient.$showLockScreenLyrics
            .combineLatest(cardState.$isArtworkLifted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showLyrics, isLifted in
                self?.applyLyricsModeResize(showLyrics: showLyrics, isLifted: isLifted)
                self?.applyLyricsConsumerState(showLyrics: showLyrics)
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
        // Backdrop FIRST so it lands at the bottom of the SkyLight
        // space's z-order; the card stacks on top.
        if backdropPanel == nil {
            backdropPanel = registerAndAssign(makeBackdropPanel())
        }
        if panel == nil {
            panel = registerAndAssign(makePanel())
        }
        if lockNotchPanel == nil {
            let lp = registerAndAssign(makeLockNotchPanel())
            lockNotchPanel = lp
            lockNotchFullFrame = lp.frame
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

    private func startKeyboardPoll() {
        stopKeyboardPoll()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            // Timer is added to RunLoop.main so the callback fires on
            // the main thread; assume the isolation directly instead
            // of doing the extra DispatchQueue.main.async hop the old
            // code had.
            MainActor.assumeIsolated { self?.tickKeyboardPoll() }
        }
        RunLoop.main.add(t, forMode: .common)
        keyboardPollTimer = t
    }

    private func stopKeyboardPoll() {
        keyboardPollTimer?.invalidate()
        keyboardPollTimer = nil
    }

    /// Read seconds since the last `.keyDown` from the combined
    /// session-state event source and flip `cardState.keyboardActive`
    /// when crossing the active-window threshold. Secure-input mode
    /// (engaged by the lock-screen password field) masks key *content*
    /// but not event *timestamps*, so this reading still updates.
    private func tickKeyboardPoll() {
        let since = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        )
        let active = since < keyboardActiveWindow
        if cardState.keyboardActive != active {
            cardState.keyboardActive = active
        }
    }

    private func installObservers() {
        lockObserver.onLocked = { [weak self] in self?.locked = true; self?.refreshVisibility() }
        lockObserver.onUnlocked = { [weak self] in self?.locked = false; self?.refreshVisibility() }
        lockObserver.onScreensaverStart = { [weak self] in self?.locked = true; self?.refreshVisibility() }
        lockObserver.onScreensaverStop = { [weak self] in self?.locked = false; self?.refreshVisibility() }
        lockObserver.start()

        // Pre-lock detection: as soon as the workspace resigns active,
        // bring the lock chrome on screen so it's already up by the
        // time the system finishes dimming. Without this, the panel
        // pops in a few hundred ms late and the user catches the
        // empty frame.
        lockObserver.$isPreparingLock
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        idleMonitor.threshold = TimeInterval(ambient.lockScreenWidgetIdleTimeoutSeconds)
        idleMonitor.onIdle = { [weak self] in self?.idle = true; self?.refreshVisibility() }
        idleMonitor.onActive = { [weak self] in self?.idle = false; self?.refreshVisibility() }
        idleMonitor.start()

        // Keyboard activity poll so the backdrop knows when to fade
        // out for the lock-screen password field.
        startKeyboardPoll()

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
        stopKeyboardPoll()
        blurService.stop()
        panel?.orderOut(nil)
        panel = nil
        lockNotchPanel?.orderOut(nil)
        lockNotchPanel = nil
        backdropPanel?.orderOut(nil)
        backdropPanel = nil
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
        panel.setFrame(
            NSRect(origin: position(on: screen, size: currentPanelSize), size: currentPanelSize),
            display: true
        )
    }

    /// Swap panel size between the compact and lyrics dimensions.
    /// Animated so the resize moves with the SwiftUI lift spring rather
    /// than snapping mid-transition.
    ///
    /// Deferred one main-queue cycle. The sink driving this fires from
    /// a `withAnimation { cardState.isArtworkLifted.toggle() }` inside
    /// the SwiftUI tap handler — i.e. mid-layout-pass. Calling
    /// `panel.animator().setFrame(...)` synchronously from there
    /// produces the `_NSDetectedLayoutRecursion` warning. One async
    /// hop pushes the AppKit frame change out of the SwiftUI layout
    /// pass cleanly.
    private func applyLyricsModeResize(showLyrics: Bool, isLifted: Bool) {
        let target = (showLyrics && isLifted) ? Self.lyricsPanelSize : Self.compactPanelSize
        guard target != currentPanelSize else { return }
        currentPanelSize = target

        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let screen = NSScreen.main?.frame else { return }
            let origin = self.position(on: screen, size: target)
            let frame = NSRect(origin: origin, size: target)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            })
        }
    }

    /// Register or unregister the lock-screen card as a lyrics consumer.
    /// Drives on-demand fetching: lyrics service only hits LRCLIB while
    /// at least one consumer is active.
    private func applyLyricsConsumerState(showLyrics: Bool) {
        MediaControls.shared.lyrics.setConsumer(
            Self.lyricsConsumerKey,
            active: showLyrics
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
        // `locked` flips on the DNC lock event; `isPreparingLock` flips on
        // sessionDidResignActive, which precedes lock by a few hundred ms.
        // Treating both as "showing lock presentation" eliminates the
        // blank flash that used to appear right at lock time.
        let shouldShow = locked || idle || lockObserver.isPreparingLock

        // Backdrop rides the same show/hide as the card; opacity of
        // the blurred art + tint inside is gated by isArtworkLifted.
        if let backdropPanel {
            if shouldShow, !backdropPanel.isVisible {
                backdropPanel.orderFrontRegardless()
            } else if !shouldShow, backdropPanel.isVisible {
                backdropPanel.orderOut(nil)
            }
        }

        // Music card: simple show / hide.
        if let panel {
            if shouldShow, !panel.isVisible {
                panel.orderFrontRegardless()
            } else if !shouldShow, panel.isVisible {
                panel.orderOut(nil)
            }
        }

        // Lock notch: show immediately at full size; on hide play a
        // brief hold (so the SF Symbol morph runs) then a horizontal
        // shrink toward the center.
        if let lockNotchPanel {
            if shouldShow {
                lockNotchHideTask?.cancel()
                lockNotchHideTask = nil
                // Restore full frame in case we caught the panel
                // mid-shrink from a previous unlock.
                lockNotchPanel.setFrame(lockNotchFullFrame, display: true)
                lockNotchPanel.alphaValue = 1
                if !lockNotchPanel.isVisible {
                    lockNotchPanel.orderFrontRegardless()
                }
            } else if lockNotchPanel.isVisible {
                scheduleLockNotchHide()
            }
        }
    }

    /// Hold the lock notch visible briefly after unlock so the SF Symbol
    /// morph plays out, then animate the panel's width to zero from the
    /// center before orderOut. Cancelled (and the panel restored to its
    /// full frame) if the Mac re-locks during the hold or shrink.
    private func scheduleLockNotchHide() {
        lockNotchHideTask?.cancel()
        lockNotchHideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.lockNotchUnlockHoldDuration))
            guard !Task.isCancelled,
                  let lockNotchPanel = self.lockNotchPanel,
                  lockNotchPanel.isVisible else { return }
            if self.locked || self.idle { return }

            // Horizontal shrink toward the center: width → 0, height
            // and y unchanged, x walks inward so the midpoint stays
            // put. NSAnimationContext on the animator-proxy frame.
            let fullFrame = self.lockNotchFullFrame
            let collapsed = NSRect(
                x: fullFrame.midX,
                y: fullFrame.minY,
                width: 0,
                height: fullFrame.height
            )
            // Capture the few main-actor values the animation block
            // needs as locals so the closures don't have to reach
            // back through `self` (which would trip Swift 6's
            // Sendable-closure isolation diagnostics — both
            // `runAnimationGroup`'s `changes` and `completionHandler`
            // are Sendable closures even though AppKit guarantees they
            // run on main).
            let shrinkDuration = self.lockNotchShrinkDuration
            let fullFrame_ = self.lockNotchFullFrame

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = shrinkDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                lockNotchPanel.animator().setFrame(collapsed, display: true)
            }, completionHandler: { [weak self] in
                // AppKit calls the completion handler on the main
                // thread, so we can assert main-actor isolation and
                // touch our main-actor state safely.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let panel = self.lockNotchPanel else { return }
                    // If state flipped during the shrink, snap back
                    // to full size and stay visible; otherwise hide +
                    // restore frame for the next show.
                    if self.locked || self.idle {
                        panel.setFrame(fullFrame_, display: true)
                    } else {
                        panel.orderOut(nil)
                        panel.setFrame(fullFrame_, display: false)
                    }
                }
            })
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let size = currentPanelSize
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
            cardState: cardState,
            lyricsService: MediaControls.shared.lyrics,
            ambient: ambient,
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
        // Total width is owned by LockNotchIndicatorView so the panel
        // sizing and the SwiftUI layout never get out of sync.
        let totalSize = CGSize(
            width: LockNotchIndicatorView.totalWidth(for: notchSize),
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

    /// Full-screen backdrop panel — blurred album art + accent radial
    /// gradient that fades in only while the music card's artwork is
    /// in the lifted state. Sits behind the music card and lock notch
    /// indicator in the same SkyLight space.
    private func makeBackdropPanel() -> NSPanel {
        let screen = NSScreen.main?.frame ?? .zero

        let p = NSPanel(
            contentRect: screen,
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
        // Display-only — pass mouse events through to whatever's
        // underneath (lock screen / desktop).
        p.ignoresMouseEvents = true
        p.canBecomeVisibleWithoutLogin = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // One step below the music card + lock-notch indicator so
        // they stack on top within the SkyLight space.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        p.alphaValue = 1
        p.animationBehavior = .none

        let host = NSHostingView(rootView: LockScreenBackdropView(
            musicState: MediaControls.shared.state,
            cardState: cardState,
            blurService: blurService
        ))
        host.frame = NSRect(origin: .zero, size: screen.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }
}
