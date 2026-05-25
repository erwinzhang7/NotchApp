import Combine
import Foundation

/// Toggles + persistence for the ambient dashboard's optional bottom row
/// and the lock-screen music widget.
@MainActor
final class AmbientSettings: ObservableObject {
    static let shared = AmbientSettings()

    @Published var showCalendar: Bool {
        didSet { UserDefaults.standard.set(showCalendar, forKey: Keys.showCalendar) }
    }

    @Published var showReminders: Bool {
        didSet { UserDefaults.standard.set(showReminders, forKey: Keys.showReminders) }
    }

    /// Master toggle for the small SkyLight-backed widget that shows the
    /// music card above the macOS lock screen. Opt-in because it uses a
    /// private API.
    @Published var lockScreenWidgetEnabled: Bool {
        didSet { UserDefaults.standard.set(lockScreenWidgetEnabled, forKey: Keys.lockScreenWidgetEnabled) }
    }

    /// Seconds of HID inactivity before the lock-screen widget shows on
    /// the desktop (it always shows when the Mac is actually locked).
    @Published var lockScreenWidgetIdleTimeoutSeconds: Int {
        didSet { UserDefaults.standard.set(lockScreenWidgetIdleTimeoutSeconds, forKey: Keys.lockScreenWidgetIdleTimeoutSeconds) }
    }

    private enum Keys {
        static let showCalendar                       = "ambient.showCalendar"
        static let showReminders                      = "ambient.showReminders"
        static let lockScreenWidgetEnabled            = "lockScreenWidget.enabled"
        static let lockScreenWidgetIdleTimeoutSeconds = "lockScreenWidget.idleTimeoutSeconds"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showCalendar:                       true,
            Keys.showReminders:                      true,
            Keys.lockScreenWidgetEnabled:            false,
            Keys.lockScreenWidgetIdleTimeoutSeconds: 180,
        ])
        self.showCalendar                       = defaults.bool(forKey: Keys.showCalendar)
        self.showReminders                      = defaults.bool(forKey: Keys.showReminders)
        self.lockScreenWidgetEnabled            = defaults.bool(forKey: Keys.lockScreenWidgetEnabled)
        self.lockScreenWidgetIdleTimeoutSeconds = defaults.integer(forKey: Keys.lockScreenWidgetIdleTimeoutSeconds)
    }
}
