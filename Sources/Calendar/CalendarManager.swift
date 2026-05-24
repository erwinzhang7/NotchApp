import Foundation

/// Façade for the Calendar module. Same shape as ClipboardManager / MediaControls:
/// a Services holder reachable via `CalendarManager.shared`. The service does
/// NOT auto-request EventKit access at launch — permission is requested only
/// when the user explicitly grants it from the Ambient tab UI, so the app
/// doesn't surprise the user with a system prompt at boot.
enum CalendarManager {
    @MainActor static let shared: Services = Services()

    @MainActor
    final class Services {
        let service: CalendarService
        let settings: CalendarSettings

        init() {
            let settings = CalendarSettings()
            self.settings = settings
            self.service = CalendarService(settings: settings)
            service.refreshAccessStatus()
            service.refreshIfAuthorized()
        }
    }
}
