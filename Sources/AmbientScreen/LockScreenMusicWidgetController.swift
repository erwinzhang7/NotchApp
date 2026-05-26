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

    /// Panel height. Width spans the full main display so SwiftUI
    /// content can position columns at screen-relative percentages
    /// (artwork+card centered at 25% from left, lyrics starting at
    /// midpoint+20pt). Computed lazily — see `currentPanelSize`.
    ///
    /// **Why static height + dynamic width**: the previous revision
    /// flipped the panel between 480pt and 720pt via
    /// `panel.animator().setFrame(...)` when the lyrics column
    /// needed to appear, which triggered a SwiftUI + NSHostingView
    /// constraint-update feedback loop crashing the app with
    /// NSGenericException. Sizing the panel once at the full screen
    /// width (and never resizing it) lets SwiftUI animate content
    /// inside without ever touching `panel.animator()`.
    private static let panelHeight: CGFloat = 540

    /// Resolved panel size at the moment of panel construction.
    /// Width = the main display's logical width; height = `panelHeight`.
    /// Captured into the instance at `makePanel` time so screen
    /// reconfiguration after launch doesn't silently un-fit the panel.
    private var currentPanelSize: NSSize = NSSize(width: 1512, height: 540)
    /// Stable consumer key the controller uses to subscribe to the
    /// lyrics service. String constant so registration is idempotent.
    private static let lyricsConsumerKey = "lockScreen"

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

        // Register / unregister the lock-screen card as a lyrics
        // consumer based on the setting. No panel-resize anymore —
        // panel is fixed at panelSize so the SwiftUI content can
        // animate inside without triggering the NSHostingView
        // constraint-update feedback loop.
        ambient.$showLockScreenLyrics
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showLyrics in
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
        logPanelConfiguration()
    }

    /// One-shot forensic log of each lock-screen panel's configuration.
    /// If a future lockout happens, the user's Console output will
    /// definitively show whether our defenses are wired correctly: is
    /// the music card actually a `LockScreenWidgetPanel`? Is
    /// canBecomeKey false? Is ignoresMouseEvents set? Etc. Without
    /// this trace, post-mortem debugging would be guesswork.
    private func logPanelConfiguration() {
        func summarize(_ label: String, _ p: NSPanel?) {
            guard let p else {
                NSLog("[LockSafety] %@: nil", label)
                return
            }
            NSLog("[LockSafety] %@: class=%@ canBecomeKey=%@ canBecomeMain=%@ ignoresMouseEvents=%@ level=%d alphaValue=%.2f",
                  label,
                  String(describing: type(of: p)),
                  p.canBecomeKey ? "Y" : "N",
                  p.canBecomeMain ? "Y" : "N",
                  p.ignoresMouseEvents ? "Y" : "N",
                  p.level.rawValue,
                  p.alphaValue)
        }
        summarize("musicCard", panel)
        summarize("backdrop", backdropPanel)
        summarize("lockNotch", lockNotchPanel)
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
        lockObserver.onLocked = { [weak self] in
            // Safety: force the artwork back to its compact state on
            // every lock so the full-screen backdrop never starts the
            // session opaque. Combined with the LockScreenWidgetPanel
            // canBecomeKey=false guard, this gives the loginwindow's
            // password field both visibility and key focus the moment
            // the lock screen appears.
            self?.cardState.isArtworkLifted = false
            self?.locked = true
            self?.refreshVisibility()
        }
        lockObserver.onUnlocked = { [weak self] in self?.locked = false; self?.refreshVisibility() }
        lockObserver.onScreensaverStart = { [weak self] in
            self?.cardState.isArtworkLifted = false
            self?.locked = true
            self?.refreshVisibility()
        }
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
    /// whenever the offset slider moves. Width tracks the main
    /// display's logical width so the SwiftUI inside can position
    /// columns at screen-relative percentages.
    private func recenter() {
        guard let panel, let screen = NSScreen.main?.frame else { return }
        currentPanelSize = NSSize(width: screen.width, height: Self.panelHeight)
        panel.setFrame(
            NSRect(origin: position(on: screen, size: currentPanelSize), size: currentPanelSize),
            display: true
        )
    }

    /// Register or unregister the lock-screen card as a lyrics consumer.
    /// Drives on-demand fetching: lyrics service only hits LRCLIB while
    /// at least one consumer is active.
    private func applyLyricsConsumerState(showLyrics: Bool) {
        let start = Date()
        NSLog("[Toggle] applyLyricsConsumerState showLyrics=%@", showLyrics ? "Y" : "N")
        MediaControls.shared.lyrics.setConsumer(
            Self.lyricsConsumerKey,
            active: showLyrics
        )
        NSLog("[Toggle] applyLyricsConsumerState DONE elapsed=%.3fs", Date().timeIntervalSince(start))
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
        //
        // Caffeinate gate: when any IOKit assertion is preventing
        // idle sleep (caffeinate -d / -i / -u, or anything else
        // declaring the user active), suppress the widget entirely.
        // The user explicitly does NOT want the widget overlay
        // appearing on a display that's still lit because something
        // is keeping it that way — even if the screen has security-
        // locked on schedule. IdleMonitor's tick polls assertions
        // every 5s, so caffeinate engaging mid-lock propagates via
        // an `onActive` callback within that window.
        let caffeinated = IdleMonitor.hasPreventIdleAssertion()
        let isLockState = locked || lockObserver.isPreparingLock
        let baseShould = isLockState || idle
        let shouldShow = baseShould && !caffeinated
        NSLog("[Visibility] locked=%@ idle=%@ preparing=%@ caffeinated=%@ -> show=%@ (lockState=%@)",
              locked ? "Y" : "N",
              idle ? "Y" : "N",
              lockObserver.isPreparingLock ? "Y" : "N",
              caffeinated ? "Y" : "N",
              shouldShow ? "Y" : "N",
              isLockState ? "Y" : "N")

        // Music card panel keeps `ignoresMouseEvents = false` even
        // during lock so scrubber/transport stay interactive. The
        // *keyboard* side is the actual lockout risk (panel grabs
        // key window → keys don't reach loginwindow's secure input)
        // and that's already handled by LockScreenWidgetPanel's
        // canBecomeKey = false. Mouse events route by cursor position
        // and do NOT interfere with loginwindow's password entry —
        // secure input is keyboard-only.

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
        // Full screen width so SwiftUI can position the artwork
        // column and lyrics column at absolute screen-relative
        // positions. Height fixed at `panelHeight`.
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let size = NSSize(width: screen.width, height: Self.panelHeight)
        currentPanelSize = size
        let origin = position(on: screen, size: size)
        let p = LockScreenWidgetPanel(
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

        let p = LockScreenWidgetPanel(
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

        let p = LockScreenWidgetPanel(
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

/// NSPanel subclass used for every lock-screen-surface panel (music
/// card, backdrop, lock notch). Layered defenses to ensure we can
/// never trap the user at the lock screen:
///
/// 1. `canBecomeKey = false` + `canBecomeMain = false`. Without this,
///    our panel could become key during lock → keystrokes routed to
///    us instead of loginwindow's password field → user can't unlock.
/// 2. `keyDown` defensively recognizes the ⌃⌥⌘P panic combo even
///    though (1) should prevent this method from ever being called.
///    Belt-and-suspenders: if some future SwiftUI subview or AppKit
///    quirk routes a key event here, the user can still terminate
///    NotchApp from it.
///
/// Mouse-event routing: the music card panel allows mouse events for
/// scrubber/transport in unlocked state, but the controller flips
/// `ignoresMouseEvents = true` for the duration of lock so clicks can
/// pass through to the password field even if our card visually
/// overlaps it.
final class LockScreenWidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let expected: NSEvent.ModifierFlags = [.control, .option, .command]
        if mods == expected,
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            NSLog("[NotchApp] panic hotkey via LockScreenWidgetPanel.keyDown — terminating")
            NSApp.terminate(nil)
            return
        }
        super.keyDown(with: event)
    }
}
