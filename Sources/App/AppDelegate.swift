import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchController = NotchWindowController()
    private let lockScreenWidget = LockScreenMusicWidgetController()
    /// Always-visible Dynamic-Island-style pill at the physical notch.
    /// Hides when the shell expands or the system lock screen owns the
    /// display. Wired with the shell state + the widget's lock observer
    /// so all three never visually collide.
    private lazy var idleNotchPill = IdleNotchPillController(
        shellState: notchController.state,
        lockObserver: lockScreenWidget.lockObserver
    )
    /// Event sources that feed the idle pill's activity engine.
    /// Lifecycle parallels the pill itself.
    private let powerSource = PowerActivitySource()
    private let bluetoothSource = BluetoothActivitySource()
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
        lockScreenWidget.start()
        idleNotchPill.start()
        startActivitySources()

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
        powerSource.stop()
        bluetoothSource.stop()
        nowPlayingBridge.stop()
        idleNotchPill.stop()
        lockScreenWidget.stop()
        notchController.hide()
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

    /// Spin up power / bluetooth / now-playing sources and route their
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

        nowPlayingBridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .started(let snapshot), .updated(let snapshot):
                    self.idleNotchPill.engine.showLiveActivity(
                        NowPlayingActivity(snapshot: snapshot)
                    )
                case .stopped:
                    self.idleNotchPill.engine.hideLiveActivity(
                        id: NowPlayingActivity(snapshot: .init(title: "", artist: "", artwork: nil)).id
                    )
                }
            }
            .store(in: &cancellables)
        nowPlayingBridge.start()
    }
}
