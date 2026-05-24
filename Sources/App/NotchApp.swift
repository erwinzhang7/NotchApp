import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // App.body must declare at least one Scene; we satisfy it with an
        // empty Settings scene. All real UI is driven by AppDelegate via
        // NSWindow controllers (notch shell, settings window, clipboard
        // history) because invoking the SwiftUI Settings scene
        // programmatically from an LSUIElement agent isn't reliable on
        // macOS 26 — see SettingsWindowController.
        Settings { EmptyView() }
    }
}
