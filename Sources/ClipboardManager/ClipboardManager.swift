import Foundation

/// Module façade. Owns the singleton wiring (settings ←→ store ←→ monitor) so the App entry,
/// the AppKit launcher, and (later) the notch shell all share the same instances.
///
/// Privacy guarantee: history is held by `ClipboardStore` in memory only — never serialized.
/// User PREFERENCES (capture toggles, auto-clear interval) live in UserDefaults; clipboard
/// CONTENT does not.
enum ClipboardManager {
    static let shared: Services = Services()

    final class Services {
        let settings: ClipboardSettings
        let store: ClipboardStore
        let monitor: ClipboardMonitor

        init() {
            let settings = ClipboardSettings()
            let store = ClipboardStore(settings: settings)
            let monitor = ClipboardMonitor(store: store, settings: settings)
            self.settings = settings
            self.store = store
            self.monitor = monitor
        }
    }
}
