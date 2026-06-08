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
    /// Currently-displayed date in the calendar view. Drives `selectedDateEvents`.
    /// Defaults to today; the wheel picker updates this on user selection.
    @Published private(set) var selectedDate: Date = Foundation.Calendar.current.startOfDay(for: Date())
    /// Events on `selectedDate`, fetched on demand when the date changes.
    /// Same calendar filter as `todaysEvents`.
    @Published private(set) var selectedDateEvents: [EKEvent] = []

    private let store = EKEventStore()
    private let settings: CalendarSettings
    private var cancellables: Set<AnyCancellable> = []
    private var storeChangedObserver: NSObjectProtocol?
    private var dayChangedObserver: NSObjectProtocol?

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

        // Roll the wheel to the new "today" when the calendar day changes
        // (fires at local midnight, and on wake / timezone change). Without
        // this the selected date stayed pinned to the day the app launched,
        // so each morning the wheel was centred on yesterday until the user
        // manually scrolled.
        dayChangedObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rollToToday()
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
        if let observer = dayChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Snap the displayed date back to the current day. Called on calendar
    /// day-change so the wheel auto-advances; updating `selectedDate` makes
    /// the wheel re-centre via its `onChange(of:)` and refreshes the list.
    private func rollToToday() {
        selectedDate = Foundation.Calendar.current.startOfDay(for: Date())
        refreshIfAuthorized()
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
            selectedDateEvents = []
            return
        }
        availableCalendars = store
            .calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        todaysEvents = events(on: Foundation.Calendar.current.startOfDay(for: Date()))
        selectedDateEvents = events(on: selectedDate)
    }

    /// Switch the displayed date and re-query. Cheap on EventKit — same
    /// `predicateForEvents` path as the today fetch; the store handles its
    /// own caching for repeat lookups.
    func setSelectedDate(_ date: Date) {
        let normalized = Foundation.Calendar.current.startOfDay(for: date)
        guard normalized != selectedDate else { return }
        selectedDate = normalized
        guard accessStatus == .fullAccess else {
            selectedDateEvents = []
            return
        }
        selectedDateEvents = events(on: normalized)
    }

    private func events(on day: Date) -> [EKEvent] {
        let cal = Foundation.Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: filteredCalendars())
        return store.events(matching: predicate)
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
