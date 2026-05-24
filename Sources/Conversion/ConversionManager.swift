import Foundation

/// Module façade. Same shape as the other managers (ClipboardManager,
/// MediaControls, CalendarManager, RemindersManager): a Services holder
/// reachable via `ConversionManager.shared`. Wires the settings,
/// registry, and orchestration service together and binds the service
/// to the existing FileShelfStore so converted outputs land in the shelf.
enum ConversionManager {
    @MainActor static let shared: Services = Services()

    @MainActor
    final class Services {
        let settings: ConversionSettings
        let registry: ConverterRegistry
        let service: ConversionService

        init() {
            // Force the launch-time image encoding self-test to run BEFORE
            // ConversionSettings.init reads the saved default format (so
            // it can validate against the probe result and auto-fall-back
            // if necessary). The static let is then cached for the rest
            // of the app's lifetime — no per-right-click re-probing.
            _ = ImageEncodingCapability.writableFormats

            let settings = ConversionSettings()
            let registry = ConverterRegistry(settings: settings)
            self.settings = settings
            self.registry = registry
            self.service = ConversionService(
                registry: registry,
                settings: settings,
                shelfStore: FileShelf.shared.store
            )
        }
    }
}
