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

    private enum Keys {
        static let showCalendar  = "ambient.showCalendar"
        static let showReminders = "ambient.showReminders"
    }

    init() {
        let defaults = UserDefaults.standard
        // First-launch default for both is ON. UserDefaults returns false
        // for missing booleans, so we register defaults explicitly.
        defaults.register(defaults: [
            Keys.showCalendar:  true,
            Keys.showReminders: true,
        ])
        self.showCalendar  = defaults.bool(forKey: Keys.showCalendar)
        self.showReminders = defaults.bool(forKey: Keys.showReminders)
    }
}
