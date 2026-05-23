import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            ClipboardSettingsView(
                settings: ClipboardManager.shared.settings,
                store: ClipboardManager.shared.store
            )
        }
    }
}
