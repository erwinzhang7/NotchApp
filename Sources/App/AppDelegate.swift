import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchController = NotchWindowController()
    private lazy var historyWindow = ClipboardHistoryWindowController(store: ClipboardManager.shared.store)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notchController.show()
        ClipboardManager.shared.monitor.start()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.monitor.stop()
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
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14+ Settings scene; selector is the supported escape hatch from AppKit code.
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func showHistory() {
        historyWindow.show()
    }
}
