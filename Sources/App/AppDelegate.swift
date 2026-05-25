import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchController = NotchWindowController()
    private let lockScreenWidget = LockScreenMusicWidgetController()
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
}
