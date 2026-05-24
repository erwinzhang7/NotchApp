import Combine
import Foundation

/// Which reminder list to show. `nil` (default) means "all scheduled" —
/// every incomplete reminder with a due date across all lists, soonest
/// first. Setting to a specific calendar identifier narrows to that list.
@MainActor
final class RemindersSettings: ObservableObject {
    @Published var selectedListID: String? {
        didSet {
            if let id = selectedListID {
                UserDefaults.standard.set(id, forKey: Keys.selectedListID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedListID)
            }
        }
    }

    private enum Keys {
        static let selectedListID = "reminders.selectedListID"
    }

    init() {
        self.selectedListID = UserDefaults.standard.string(forKey: Keys.selectedListID)
    }
}
