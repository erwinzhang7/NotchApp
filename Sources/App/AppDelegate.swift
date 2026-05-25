import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchController = NotchWindowController()
    private let lockScreenWidget = LockScreenMusicWidgetController()
    private lazy var historyWindow = ClipboardHistoryWindowController(store: ClipboardManager.shared.store)
    private lazy var settingsWindow = SettingsWindowController()
    private var statusItem: NSStatusItem?

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
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.monitor.stop()
        MediaControls.shared.adapter.stop()
        lockScreenWidget.stop()
        notchController.hide()
    }

    // MARK: - Status-bar launcher
    // Temporary entry point: this LSUIElement app has no dock icon and the notch shell doesn't
    // yet host the launcher UI. The status item gives the user a way to reach Settings and the
    // History window. Remove once NotchShell mounts those affordances.
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        // Skip NSApp.sendAction(Selector("showSettingsWindow:"), …): on
        // macOS 26 from an LSUIElement agent the SwiftUI Settings scene
        // isn't reachable via the responder chain (no key window to anchor
        // it on) and the action silently no-ops. SettingsWindowController
        // owns the NSWindow directly and brings the app to front itself.
        settingsWindow.show()
    }

    @objc private func showHistory() {
        historyWindow.show()
    }
}
