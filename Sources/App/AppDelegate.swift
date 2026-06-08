import AppKit
import Combine
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reliable reference to the live AppDelegate. `NSApp.delegate` is a
    /// SwiftUI-internal forwarding delegate under @NSApplicationDelegateAdaptor
    /// on macOS 26, so `NSApp.delegate as? AppDelegate` is nil — callers that
    /// need the delegate (e.g. the notch right-click menu) must go through
    /// this. Weak because @NSApplicationDelegateAdaptor owns the strong ref.
    static weak var shared: AppDelegate?

    private let notchController = NotchWindowController()
    private let lockScreenWidget = LockScreenMusicWidgetController()
    /// Per-display fullscreen detector so the idle pill hides over
    /// fullscreen videos (YouTube / Netflix / QuickTime) instead of
    /// drawing on top of them. Shared across observers that need this.
    private let fullscreenObserver = FullscreenSpaceObserver()
    /// Global drag monitor: pre-expands the notch when a drag from
    /// another app crosses the notch hot region, before SwiftUI's
    /// `.onDrop` would fire. Drives `NotchState.isDragHinted`.
    private let dragDetector = DragDetector()
    /// Always-visible Dynamic-Island-style pill at the physical notch.
    /// Hides when the shell expands, the system lock screen owns the
    /// display, or the display is in a macOS-fullscreen space.
    private lazy var idleNotchPill = IdleNotchPillController(
        shellState: notchController.state,
        lockObserver: lockScreenWidget.lockObserver,
        fullscreenObserver: fullscreenObserver
    )
    /// Event sources that feed the idle pill's activity engine.
    /// Lifecycle parallels the pill itself.
    private let powerSource = PowerActivitySource()
    private let bluetoothSource = BluetoothActivitySource()
    private let brightnessSource = BrightnessActivitySource()
    private let volumeSource = VolumeActivitySource()
    /// Hardware-key suppressor: intercepts brightness/volume/mute keys
    /// before macOS shows its native HUD so the user only sees the
    /// notch activity. Lazy because it captures the sources above.
    private lazy var mediaKeySuppressor = MediaKeySuppressor(
        brightness: brightnessSource,
        volume: volumeSource
    )
    /// Standalone "Copied N characters" banner that drops down BELOW
    /// the notch when the auto-copy-on-selection feature fires. Has
    /// its own NSPanel so it doesn't fight for screen space with the
    /// idle pill (now-playing, charging, etc.).
    private let copyBanner = CopyBannerController()
    private lazy var nowPlayingBridge = NowPlayingActivityBridge(
        nowPlaying: MediaControls.shared.state
    )
    /// Default temporary-notification duration. Hardcoded because the
    /// settings sheet that would have hosted per-event durations isn't
    /// being ported.
    private static let temporaryActivityDuration: TimeInterval = 3.0
    private lazy var historyWindow = ClipboardHistoryWindowController(store: ClipboardManager.shared.store)
    private lazy var settingsWindow = SettingsWindowController()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Publish a reliable reference to ourselves. `NSApp.delegate` is
        // NOT this instance under @NSApplicationDelegateAdaptor on macOS 26
        // — SwiftUI installs its own forwarding delegate — so anything that
        // did `NSApp.delegate as? AppDelegate` (e.g. the notch right-click
        // menu) silently got nil and no-op'd. Reach the delegate through
        // this static instead.
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        notchController.show()
        ClipboardManager.shared.monitor.start()
        // Force-init these so the adapter subprocess + EventKit observers
        // are running by the time the user opens the Ambient tab. None of
        // them auto-request permission — the EventKit modules prompt only
        // when the user clicks "Grant Access" from the inline UI.
        _ = MediaControls.shared
        _ = CalendarManager.shared
        _ = RemindersManager.shared
        _ = ConversionManager.shared
        TokenUsageStore.shared.start()
        lockScreenWidget.start()
        fullscreenObserver.start()
        idleNotchPill.start()

        // Pre-window drag greeting: when a global drag with valid shelf
        // content enters the notch hot region, push isDragHinted=true so
        // the panel expands before the cursor reaches the small pill.
        // Cleared on exit / mouse-up; SwiftUI's onDrop takes over once the
        // drag actually crosses into the (now-expanded) panel.
        dragDetector.notchRegion = { [weak self] in
            self?.notchController.currentCollapsedFrame ?? .zero
        }
        dragDetector.onEnter = { [weak self] in
            self?.notchController.state.isDragHinted = true
        }
        dragDetector.onExit = { [weak self] in
            self?.notchController.state.isDragHinted = false
        }
        dragDetector.start()
        // Hot-zone tracking: shell hover/drag detection uses the idle pill's
        // current visible size, so widening activities (NowPlaying etc.)
        // grow the interactive area to match.
        notchController.bindActivityEngine(idleNotchPill.engine)
        startActivitySources()
        mediaKeySuppressor.start()
        registerGlobalShortcuts()

        // Install / remove the status-bar item live in response to the
        // user toggling "Show in Menu Bar" (toggle lives in the notch
        // panel's right-click menu).
        let ambient = AmbientSettings.shared
        applyMenuBarVisibility(ambient.showInMenuBar)
        ambient.$showInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.applyMenuBarVisibility(visible) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.monitor.stop()
        MediaControls.shared.adapter.stop()
        TokenUsageStore.shared.stop()
        powerSource.stop()
        bluetoothSource.stop()
        brightnessSource.stop()
        volumeSource.stop()
        mediaKeySuppressor.stop()
        copyBanner.stop()
        nowPlayingBridge.stop()
        dragDetector.stop()
        idleNotchPill.stop()
        fullscreenObserver.stop()
        lockScreenWidget.stop()
        notchController.hide()
        // Wipe any temp files we materialized for non-file drags (web URLs,
        // text snippets, file-promise payloads). Safe — only touches our
        // own /tmp/NotchApp/Shelf/ subtree.
        TemporaryShelfStorage.purgeAll()
    }

    // MARK: - Status-bar launcher
    //
    // Optional entry point: this LSUIElement app has no dock icon. When
    // the user disables the status item the same actions remain reachable
    // through the notch panel's right-click context menu.

    private func applyMenuBarVisibility(_ visible: Bool) {
        if visible {
            if statusItem == nil { installStatusItem() }
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "NotchApp")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(title: "Show Clipboard History", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    // MARK: - Actions
    //
    // Exposed (internal) so the notch panel's right-click menu can fire
    // them via NSApp.delegate without the responder-chain dance.

    @objc func openSettings() {
        // Skip NSApp.sendAction(Selector("showSettingsWindow:"), …): on
        // macOS 26 from an LSUIElement agent the SwiftUI Settings scene
        // isn't reachable via the responder chain (no key window to anchor
        // it on) and the action silently no-ops. SettingsWindowController
        // owns the NSWindow directly and brings the app to front itself.
        settingsWindow.show()
    }

    @objc func showHistory() {
        historyWindow.show()
    }

    @objc func hideMenuBarIcon() {
        AmbientSettings.shared.showInMenuBar = false
    }

    // MARK: - Activity wiring

    /// Spin up temporary and live activity sources and route their
    /// events into the idle pill's engine. Each branch translates the
    /// source's domain event into a NotchActivity and the appropriate
    /// engine call. Subscriptions live for the app's lifetime.
    private func startActivitySources() {
        powerSource.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .plugged:
                    self.idleNotchPill.engine.showTemporary(
                        ChargingActivity(
                            batteryLevel: self.powerSource.batteryLevel,
                            isCharging: self.powerSource.isCharging
                        ),
                        duration: Self.temporaryActivityDuration
                    )
                case .lowPower:
                    self.idleNotchPill.engine.showTemporary(
                        LowPowerActivity(batteryLevel: self.powerSource.batteryLevel),
                        duration: Self.temporaryActivityDuration
                    )
                case .fullPower:
                    self.idleNotchPill.engine.showTemporary(
                        FullPowerActivity(batteryLevel: self.powerSource.batteryLevel),
                        duration: Self.temporaryActivityDuration
                    )
                }
            }
            .store(in: &cancellables)
        powerSource.start()

        bluetoothSource.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected(let device):
                    self.idleNotchPill.engine.showTemporary(
                        BluetoothConnectedActivity(device: device),
                        duration: Self.temporaryActivityDuration
                    )
                }
            }
            .store(in: &cancellables)
        bluetoothSource.start()

        brightnessSource.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.idleNotchPill.engine.showTemporary(
                    BrightnessActivity(level: level),
                    duration: Self.temporaryActivityDuration
                )
            }
            .store(in: &cancellables)
        brightnessSource.start()

        volumeSource.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.idleNotchPill.engine.showTemporary(
                    VolumeActivity(level: snapshot.level, isMuted: snapshot.isMuted),
                    duration: Self.temporaryActivityDuration
                )
            }
            .store(in: &cancellables)
        volumeSource.start()

        // Auto-copy-on-selection → notch banner. The selection monitor
        // only fires when the captured text actually entered the store
        // (consecutive-dedup miss), so we don't need to re-check here.
        // Skip while the lock screen owns the display — the idle pill
        // is hidden in that state.
        // Banner fires for any text added to the clipboard store —
        // manual Cmd+C, auto-copy-on-selection, anything that lands as
        // a text item. Single source of truth; avoids the prior race
        // where the banner only fired via the SelectionMonitor path
        // and missed manual copies.
        ClipboardManager.shared.store.textCopied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] copied in
                guard let self else { return }
                if self.lockScreenWidget.lockObserver.isLocked { return }
                self.copyBanner.show(
                    characterCount: copied.characterCount,
                    lineCount: copied.lineCount
                )
            }
            .store(in: &cancellables)

        nowPlayingBridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .started(let activity), .updated(let activity):
                    self.idleNotchPill.engine.showLiveActivity(activity)
                case .stopped:
                    self.idleNotchPill.engine.hideLiveActivity(
                        id: NowPlayingActivity(
                            snapshot: .init(title: "", artist: "", artwork: nil, isPlaying: false),
                            equalizerColor: .gray
                        ).id
                    )
                }
            }
            .store(in: &cancellables)
        nowPlayingBridge.start()

        // Forward shell visibility state through the legacy consumer API.
        // LyricsService currently prefetches independently of consumers,
        // but keeping this wiring avoids coupling the view to that policy.
        NotchLyricsToggleState.shared.$enabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { enabled in
                NSLog("[Lyrics] AppDelegate sees toggle=%@, registering shell consumer", enabled ? "Y" : "N")
                MediaControls.shared.lyrics.setConsumer("shell", active: enabled)
            }
            .store(in: &cancellables)
        NSLog("[Lyrics] AppDelegate subscribed to NotchLyricsToggleState")
    }

    /// Register a system-wide panic hotkey (⌃⌥⌘P) that immediately
    /// terminates NotchApp. Global monitor catches the keystroke even
    /// Bind each user-configurable shortcut to its action. The
    /// KeyboardShortcuts library persists user bindings + handles
    /// (un)registration with the system globally; we just supply the
    /// closures. Replaces the bespoke ⌃⌥⌘P panic hotkey — users who
    /// want a kill-switch can bind one to the shortcut of their choice
    /// (e.g. via a custom "togglePin" or by adding a new entry here).
    private func registerGlobalShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .togglePin) { [weak self] in
            self?.notchController.state.togglePinned()
        }
        KeyboardShortcuts.onKeyDown(for: .showClipboardHistory) { [weak self] in
            self?.showHistory()
        }
        KeyboardShortcuts.onKeyDown(for: .pasteTopClip) {
            guard let top = ClipboardManager.shared.store.items.first else { return }
            ClipboardManager.shared.store.copyToPasteboard(top)
            // Simulate ⌘V so the topmost target app receives the paste.
            // Synthesized via CGEvent so it works even when NotchApp isn't
            // frontmost.
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
        KeyboardShortcuts.onKeyDown(for: .airDropTopShelfItem) {
            // FileShelfStripView appends new tiles to the right; the most
            // recent shelf item is `items.last`, matching the visible "top"
            // when viewing the strip (newest closest to the user's eye).
            guard let top = FileShelf.shared.store.items.last,
                  let url = FileShelf.shared.store.resolvedURL(for: top) else { return }
            AirDropService.send([url])
        }
        KeyboardShortcuts.onKeyDown(for: .clearShelf) {
            FileShelf.shared.store.clearAll()
        }
        KeyboardShortcuts.onKeyDown(for: .openSettings) { [weak self] in
            self?.openSettings()
        }
    }
}
