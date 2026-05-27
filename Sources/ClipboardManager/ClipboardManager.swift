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

        struct SelectionCopied: Equatable {
            let characterCount: Int
            let lineCount: Int
        }
        /// Emitted whenever a selection was just captured AND actually
        /// inserted (i.e., the consecutive-dedup didn't suppress it).
        /// AppDelegate subscribes to drive the "Copied N characters" /
        /// "Copied N lines" notch banner.
        let selectionCopiedEvents = PassthroughSubject<SelectionCopied, Never>()

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
            // anywhere, and publish the count for the notch banner.
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
                        let lineCount = captured.text
                            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                            .count
                        self.selectionCopiedEvents.send(
                            SelectionCopied(
                                characterCount: captured.text.count,
                                lineCount: max(1, lineCount)
                            )
                        )
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
