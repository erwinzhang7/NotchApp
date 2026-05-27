import AppKit
import Combine
import Foundation

/// Module façade. Owns the singleton wiring (settings ←→ store ←→ monitor) so the App entry,
/// the AppKit launcher, and (later) the notch shell all share the same instances.
///
/// Privacy guarantee: history is held by `ClipboardStore` in memory only — never serialized.
/// User PREFERENCES (capture toggles, auto-clear interval) live in UserDefaults; clipboard
/// CONTENT does not.
enum ClipboardManager {
    @MainActor static let shared: Services = Services()

    @MainActor
    final class Services {
        let settings: ClipboardSettings
        let store: ClipboardStore
        let monitor: ClipboardMonitor
        let selectionMonitor: SelectionMonitor

        private var settingsCancellable: AnyCancellable?
        private var selectionCancellable: AnyCancellable?

        init() {
            let settings = ClipboardSettings()
            let store = ClipboardStore(settings: settings)
            let monitor = ClipboardMonitor(store: store, settings: settings)
            let selectionMonitor = SelectionMonitor()
            self.settings = settings
            self.store = store
            self.monitor = monitor
            self.selectionMonitor = selectionMonitor

            // Translate each captured selection into a clipboard write.
            // The store's fingerprint dedup decides whether it's actually
            // new; if so, mirror to NSPasteboard so the user can paste it
            // anywhere. The notch banner is driven by `store.textCopied`
            // (fires for ANY text that lands in the store, so manual Cmd+C
            // copies trigger it too), not from here.
            self.selectionCancellable = selectionMonitor.events
                .receive(on: DispatchQueue.main)
                .sink { [weak self] captured in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let item = ClipboardItem(
                            kind: .text(captured.text),
                            capturedAt: Date()
                        )
                        let inserted = self.store.add(item)
                        guard inserted else { return }
                        self.store.copyToPasteboard(item)
                    }
                }

            // Start / stop the selection monitor in response to the
            // user toggle. The monitor itself is idempotent — repeated
            // start() calls are no-ops once observers are installed.
            self.settingsCancellable = settings.$autoCopySelection
                .receive(on: DispatchQueue.main)
                .removeDuplicates()
                .sink { [weak self] enabled in
                    MainActor.assumeIsolated {
                        if enabled {
                            self?.selectionMonitor.start()
                        } else {
                            self?.selectionMonitor.stop()
                        }
                    }
                }
        }
    }
}
