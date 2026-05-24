import AppKit
import Combine
import EventKit
import Foundation

/// Wraps EKEventStore for the calendar use case. Publishes today's remaining
/// events filtered by user-selected calendars; refreshes on store-changed
/// notifications and on settings changes. Lazy: never auto-requests
/// permission — the UI surfaces a "Grant access" button when status is
/// .notDetermined.
@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var accessStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var availableCalendars: [EKCalendar] = []
    /// Today's events from the start of day, filtered by selectedCalendarIDs,
    /// sorted by startDate. Includes events that ENDED earlier today as well
    /// as upcoming ones; the view filters down to "remaining today" so users
    /// can still see the recent past at a glance.
    @Published private(set) var todaysEvents: [EKEvent] = []

    private let store = EKEventStore()
    private let settings: CalendarSettings
    private var cancellables: Set<AnyCancellable> = []
    private var storeChangedObserver: NSObjectProtocol?

    init(settings: CalendarSettings) {
        self.settings = settings

        // Cache invalidation: EventKit posts EKEventStoreChanged when any
        // event/calendar mutates anywhere on the system.
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIfAuthorized()
            }
        }

        // Re-fetch whenever the calendar selection changes.
        settings.$selectedCalendarIDs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshIfAuthorized()
            }
            .store(in: &cancellables)
    }

    deinit {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Permission

    func refreshAccessStatus() {
        accessStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Trigger the system permission prompt. macOS 14+ uses
    /// requestFullAccessToEvents. Safe to call when status is .denied or
    /// .restricted (no prompt appears, status stays the same).
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            // Use the returned Bool directly — authorizationStatus(for:) can
            // be stale for a moment after the grant and would cause
            // refreshIfAuthorized to skip the fetch.
            if granted {
                accessStatus = .fullAccess
            } else {
                refreshAccessStatus()
            }
        } catch {
            NSLog("[Calendar] requestFullAccessToEvents failed: \(error.localizedDescription)")
            refreshAccessStatus()
        }
        refreshIfAuthorized()
    }

    // MARK: - Fetch

    func refreshIfAuthorized() {
        guard accessStatus == .fullAccess else {
            availableCalendars = []
            todaysEvents = []
            return
        }
        availableCalendars = store
            .calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let cal = Foundation.Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let calendarsToQuery = filteredCalendars()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendarsToQuery
        )
        todaysEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
    }

    /// Calendars matching the user's selection, or nil for "all calendars".
    /// Returning nil to the predicate lets EventKit skip the per-calendar
    /// scan, which is also faster.
    private func filteredCalendars() -> [EKCalendar]? {
        guard settings.hasExplicitSelection else { return nil }
        let chosen = settings.selectedCalendarIDs
        let cals = store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
        return cals.isEmpty ? nil : cals
    }
}
