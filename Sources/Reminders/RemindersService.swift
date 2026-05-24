import AppKit
import Combine
import EventKit
import Foundation

/// EKEventStore wrapper for incomplete-with-due-date reminders. Publishes
/// the current scheduled list (filtered by RemindersSettings.selectedListID
/// when set, otherwise all reminder calendars), refreshes on store-changed
/// notifications and on settings changes. Mutation: markComplete writes
/// back to EventKit.
@MainActor
final class RemindersService: ObservableObject {
    @Published private(set) var accessStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var availableLists: [EKCalendar] = []
    @Published private(set) var scheduledReminders: [EKReminder] = []

    private let store = EKEventStore()
    private let settings: RemindersSettings
    private var cancellables: Set<AnyCancellable> = []
    private var storeChangedObserver: NSObjectProtocol?
    private var pendingFetchTask: Task<Void, Never>?

    init(settings: RemindersSettings) {
        self.settings = settings

        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            NSLog("[Reminders] EKEventStoreChanged received — refreshing")
            Task { @MainActor [weak self] in
                self?.refreshIfAuthorized()
            }
        }

        settings.$selectedListID
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
        let previous = accessStatus
        accessStatus = EKEventStore.authorizationStatus(for: .reminder)
        NSLog("[Reminders] accessStatus for .reminder: \(Self.describe(accessStatus)) (was \(Self.describe(previous)))")
    }

    func requestAccess() async {
        NSLog("[Reminders] requestAccess — calling requestFullAccessToReminders (entity=.reminder)")
        do {
            let granted = try await store.requestFullAccessToReminders()
            NSLog("[Reminders] requestFullAccessToReminders returned granted=\(granted)")
        } catch {
            NSLog("[Reminders] requestFullAccessToReminders threw: \(error.localizedDescription)")
        }
        refreshAccessStatus()
        refreshIfAuthorized()
    }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        // .fullAccess listed first because on macOS 14+ Apple deprecated
        // .authorized and aliased it to the same enum value as .fullAccess;
        // Swift's switch matches whichever case is listed first.
        switch status {
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        case .authorized:    return "authorized (legacy, same as fullAccess)"
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Fetch

    func refreshIfAuthorized() {
        guard accessStatus == .fullAccess else {
            NSLog("[Reminders] refresh skipped — accessStatus=\(Self.describe(accessStatus))")
            availableLists = []
            scheduledReminders = []
            return
        }
        availableLists = store
            .calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        NSLog("[Reminders] refresh — availableLists count=\(availableLists.count): [\(availableLists.map { $0.title }.joined(separator: ", "))]")

        pendingFetchTask?.cancel()
        let store = self.store
        let targets = selectedCalendarsForFetch()
        NSLog("[Reminders] refresh — fetching, target list filter=\(targets.map { $0.map { $0.title } } ?? ["<ALL>"])")
        pendingFetchTask = Task { @MainActor [weak self] in
            let fetched = await Self.fetchScheduled(store: store, calendars: targets)
            guard !Task.isCancelled else {
                NSLog("[Reminders] fetch — task cancelled before assigning")
                return
            }
            // Task is @MainActor; assignment is guaranteed on main.
            NSLog("[Reminders] fetch — assigning \(fetched.count) reminder(s) to scheduledReminders (on main actor)")
            self?.scheduledReminders = fetched
        }
    }

    private func selectedCalendarsForFetch() -> [EKCalendar]? {
        guard let id = settings.selectedListID else { return nil }
        return store.calendars(for: .reminder).first { $0.calendarIdentifier == id }.map { [$0] }
    }

    /// Fetch the visible reminder set: incomplete reminders. Reminders
    /// with a resolvable due date are sorted soonest-first; ones without
    /// a due date sort to the end alphabetically.
    ///
    /// PREDICATE CHOICE: `predicateForReminders(in:)` (broad "all reminders")
    /// rather than `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)`
    /// — the latter has historically been wobbly when both date bounds are
    /// nil and the in-Swift filter is auditable.
    ///
    /// FILTER CHOICE: we used to drop reminders without due dates ("Scheduled"
    /// semantics, matching Reminders.app's smart list). Relaxed because users
    /// with legacy iCloud Reminders get system placeholder reminders that
    /// have no due date — dropping them showed "Nothing scheduled" with no
    /// indication of why. Now everything incomplete is shown; the row UI
    /// hides the date label for reminders without one.
    private static func fetchScheduled(
        store: EKEventStore,
        calendars: [EKCalendar]?
    ) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        NSLog("[Reminders] fetchScheduled — running predicateForReminders(in:\(calendars?.map { $0.title }.description ?? "nil"))")
        return await withCheckedContinuation { (cont: CheckedContinuation<[EKReminder], Never>) in
            store.fetchReminders(matching: predicate) { fetched in
                let raw = fetched ?? []
                let incomplete = raw.filter { !$0.isCompleted }
                let withDue    = incomplete.filter { $0.resolvedDueDate != nil }
                let sorted = incomplete.sorted { (a, b) -> Bool in
                    // Reminders with due dates first (sorted by date), then
                    // dateless ones at the end sorted alphabetically.
                    switch (a.resolvedDueDate, b.resolvedDueDate) {
                    case let (lhs?, rhs?): return lhs < rhs
                    case (_?, nil):        return true
                    case (nil, _?):        return false
                    case (nil, nil):       return (a.title ?? "") < (b.title ?? "")
                    }
                }
                NSLog("[Reminders] fetchScheduled completion — raw=\(raw.count) incomplete=\(incomplete.count) withDueDate=\(withDue.count) shown=\(sorted.count). callbackOnMainThread=\(Thread.isMainThread)")
                cont.resume(returning: sorted)
            }
        }
    }

    // MARK: - Mutation

    /// Mark a reminder complete and persist immediately. Optimistically
    /// removes it from `scheduledReminders` so the UI updates without
    /// waiting for the store-changed notification round-trip.
    func markComplete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            scheduledReminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
        } catch {
            NSLog("[Reminders] markComplete failed: \(error.localizedDescription)")
        }
    }
}

extension EKReminder {
    /// Convenience: EKReminder stores due as DateComponents; resolve to a
    /// Date for sorting and display.
    var resolvedDueDate: Date? {
        guard let comps = dueDateComponents else { return nil }
        return Foundation.Calendar.current.date(from: comps)
    }
}
