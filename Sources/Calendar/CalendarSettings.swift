import Combine
import Foundation

/// User-selected calendar filter. Persists the chosen EKCalendar identifiers
/// to UserDefaults. An empty set means "show all calendars" — the implicit
/// default until the user picks specific ones.
@MainActor
final class CalendarSettings: ObservableObject {
    @Published var selectedCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                Array(selectedCalendarIDs),
                forKey: Keys.selectedCalendarIDs
            )
        }
    }

    private enum Keys {
        static let selectedCalendarIDs = "calendar.selectedCalendarIDs"
    }

    init() {
        let stored = UserDefaults.standard.array(forKey: Keys.selectedCalendarIDs) as? [String] ?? []
        self.selectedCalendarIDs = Set(stored)
    }

    /// True when the user has narrowed the calendar list — i.e. only events
    /// from the chosen calendars should appear.
    var hasExplicitSelection: Bool { !selectedCalendarIDs.isEmpty }
}
