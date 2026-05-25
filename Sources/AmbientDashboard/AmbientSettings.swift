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

    /// Whether to install the status-bar (menu bar) item on launch. When
    /// off, the menu bar is uncluttered — settings/history are reached
    /// instead by right-clicking the notch panel itself.
    @Published var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: Keys.showInMenuBar) }
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

    /// Vertical offset for the lock-screen widget, in points, from the
    /// screen center. Positive = down, negative = up. 0 = dead center.
    @Published var lockScreenWidgetVerticalOffset: Double {
        didSet { UserDefaults.standard.set(lockScreenWidgetVerticalOffset, forKey: Keys.lockScreenWidgetVerticalOffset) }
    }

    private enum Keys {
        static let showCalendar                       = "ambient.showCalendar"
        static let showReminders                      = "ambient.showReminders"
        static let showInMenuBar                      = "app.showInMenuBar"
        static let lockScreenWidgetEnabled            = "lockScreenWidget.enabled"
        static let lockScreenWidgetIdleTimeoutSeconds = "lockScreenWidget.idleTimeoutSeconds"
        static let lockScreenWidgetVerticalOffset     = "lockScreenWidget.verticalOffset"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showCalendar:                       true,
            Keys.showReminders:                      true,
            Keys.showInMenuBar:                      true,
            Keys.lockScreenWidgetEnabled:            false,
            Keys.lockScreenWidgetIdleTimeoutSeconds: 180,
            Keys.lockScreenWidgetVerticalOffset:     0,
        ])
        self.showCalendar                       = defaults.bool(forKey: Keys.showCalendar)
        self.showReminders                      = defaults.bool(forKey: Keys.showReminders)
        self.showInMenuBar                      = defaults.bool(forKey: Keys.showInMenuBar)
        self.lockScreenWidgetEnabled            = defaults.bool(forKey: Keys.lockScreenWidgetEnabled)
        self.lockScreenWidgetIdleTimeoutSeconds = defaults.integer(forKey: Keys.lockScreenWidgetIdleTimeoutSeconds)
        self.lockScreenWidgetVerticalOffset     = defaults.double(forKey: Keys.lockScreenWidgetVerticalOffset)
    }
}
