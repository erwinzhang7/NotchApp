import Combine
import Foundation

/// Toggles + persistence for the ambient dashboard's optional bottom row.
/// Music is always present (no toggle). Both bottom modules default to ON.
@MainActor
final class AmbientSettings: ObservableObject {
    static let shared = AmbientSettings()

    @Published var showCalendar: Bool {
        didSet { UserDefaults.standard.set(showCalendar, forKey: Keys.showCalendar) }
    }

    @Published var showReminders: Bool {
        didSet { UserDefaults.standard.set(showReminders, forKey: Keys.showReminders) }
    }

    // Ambient-screen prefs: control the full-screen iPad-style display
    // (AmbientScreenWindowController). The calendar / reminders visibility
    // toggles above are shared with the notch's Ambient tab — what you see
    // there also shows in the ambient screen.

    @Published var ambientScreenEnabled: Bool {
        didSet { UserDefaults.standard.set(ambientScreenEnabled, forKey: Keys.ambientScreenEnabled) }
    }

    @Published var ambientScreenTriggerOnIdle: Bool {
        didSet { UserDefaults.standard.set(ambientScreenTriggerOnIdle, forKey: Keys.ambientScreenTriggerOnIdle) }
    }

    @Published var ambientScreenIdleTimeoutSeconds: Int {
        didSet { UserDefaults.standard.set(ambientScreenIdleTimeoutSeconds, forKey: Keys.ambientScreenIdleTimeoutSeconds) }
    }

    @Published var ambientScreenDismissOnActivity: Bool {
        didSet { UserDefaults.standard.set(ambientScreenDismissOnActivity, forKey: Keys.ambientScreenDismissOnActivity) }
    }

    private enum Keys {
        static let showCalendar  = "ambient.showCalendar"
        static let showReminders = "ambient.showReminders"
        static let ambientScreenEnabled            = "ambientScreen.enabled"
        static let ambientScreenTriggerOnIdle      = "ambientScreen.triggerOnIdle"
        static let ambientScreenIdleTimeoutSeconds = "ambientScreen.idleTimeoutSeconds"
        static let ambientScreenDismissOnActivity  = "ambientScreen.dismissOnActivity"
    }

    init() {
        let defaults = UserDefaults.standard
        // First-launch defaults. UserDefaults returns false / 0 for missing
        // keys so register them explicitly.
        defaults.register(defaults: [
            Keys.showCalendar:  true,
            Keys.showReminders: true,
            Keys.ambientScreenEnabled:            true,
            Keys.ambientScreenTriggerOnIdle:      true,
            Keys.ambientScreenIdleTimeoutSeconds: 180,
            Keys.ambientScreenDismissOnActivity:  true,
        ])
        self.showCalendar  = defaults.bool(forKey: Keys.showCalendar)
        self.showReminders = defaults.bool(forKey: Keys.showReminders)
        self.ambientScreenEnabled            = defaults.bool(forKey: Keys.ambientScreenEnabled)
        self.ambientScreenTriggerOnIdle      = defaults.bool(forKey: Keys.ambientScreenTriggerOnIdle)
        self.ambientScreenIdleTimeoutSeconds = defaults.integer(forKey: Keys.ambientScreenIdleTimeoutSeconds)
        self.ambientScreenDismissOnActivity  = defaults.bool(forKey: Keys.ambientScreenDismissOnActivity)
    }
}
