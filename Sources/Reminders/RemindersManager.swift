import Foundation

/// Façade for the Reminders module. Same Services-holder shape as the
/// other modules; access is requested lazily by the user via the
/// "Grant access" button rather than at launch.
enum RemindersManager {
    @MainActor static let shared: Services = Services()

    @MainActor
    final class Services {
        let service: RemindersService
        let settings: RemindersSettings

        init() {
            let settings = RemindersSettings()
            self.settings = settings
            self.service = RemindersService(settings: settings)
            service.refreshAccessStatus()
            service.refreshIfAuthorized()
        }
    }
}
