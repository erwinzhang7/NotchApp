import AppKit
import EventKit
import SwiftUI

/// Calendar pane: month/year label + horizontal date wheel + events list
/// for the selected date. Design pattern lifted from boring.notch's
/// `BoringCalendar.swift`. Permission states handled inline so the
/// dashboard never shows a blank panel.
struct CalendarView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var settings: CalendarSettings

    var body: some View {
        VStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch service.accessStatus {
        case .fullAccess:
            authorizedContent
        case .notDetermined:
            permissionPrompt
        case .denied, .restricted, .writeOnly:
            // writeOnly grants create-only access — useless for our read
            // path, treat as denied.
            deniedHint
        @unknown default:
            deniedHint
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        header
        Divider().opacity(0.2)
        eventsList
    }

    /// Month + year stacked on the left, horizontal date wheel on the right
    /// with edge gradients fading the off-screen days into the panel
    /// background. Wheel snaps to a centered day cell; selecting a day
    /// pushes through `service.setSelectedDate`.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(service.selectedDate.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(service.selectedDate.formatted(.dateTime.year()))
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .fixedSize(horizontal: true, vertical: false)

            ZStack {
                DateWheel(
                    selected: service.selectedDate,
                    onSelect: { service.setSelectedDate($0) }
                )
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black, .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 16)
                    Spacer()
                    LinearGradient(
                        colors: [.clear, Color.black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 16)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 42)
    }

    @ViewBuilder
    private var eventsList: some View {
        let events = service.selectedDateEvents
        if events.isEmpty {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text(isToday ? "No events today" : "No events")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Text("Enjoy your free time!")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.65))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(events, id: \.eventIdentifier) { event in
                            EventRow(event: event)
                                .id(event.eventIdentifier)
                            Divider().opacity(0.15)
                        }
                    }
                }
                .onAppear { scrollToRelevant(in: events, proxy: proxy) }
                .onChange(of: events.map(\.eventIdentifier)) { _, _ in
                    scrollToRelevant(in: events, proxy: proxy)
                }
            }
        }
    }

    private var isToday: Bool {
        Foundation.Calendar.current.isDateInToday(service.selectedDate)
    }

    /// On open / event change, scroll to the first non-all-day event that
    /// hasn't ended yet, falling back to the first all-day, then the last
    /// event. Matches the at-a-glance heuristic in boring.notch.
    private func scrollToRelevant(in events: [EKEvent], proxy: ScrollViewProxy) {
        let now = Date()
        let target = events.first(where: { !$0.isAllDay && $0.endDate > now })
            ?? events.first(where: { $0.isAllDay })
            ?? events.last
        if let id = target?.eventIdentifier {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 6) {
            Text("NotchApp needs calendar access to show your day.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Grant Access") {
                Task { await service.requestAccess() }
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.secondary)
            Text("Calendar access denied")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Date wheel

/// Horizontal snap-to-center day picker. Range = 7 days past + 14 future.
/// Tap a day to select it; flick-scroll lands on the nearest day and that
/// becomes the selection. Centered with a 2-cell leading/trailing pad so
/// the first and last days can still hit the center anchor.
private struct DateWheel: View {
    let selected: Date
    let onSelect: (Date) -> Void

    /// Leading + trailing pad cells. 2 keeps "today" usable as a stop
    /// without the wheel feeling lopsided.
    private static let pad = 2
    private static let pastDays = 7
    private static let futureDays = 14

    @State private var scrollPosition: Int?

    /// True for scrollPosition updates that we drove ourselves (tap, or
    /// programmatic centering on an external `selected` change). Prevents
    /// our own snap from being mistaken for a user flick.
    @State private var programmaticScroll = false

    private var totalDays: Int { Self.pastDays + Self.futureDays + 1 }
    private var totalCells: Int { totalDays + 2 * Self.pad }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<totalCells, id: \.self) { i in
                    if isPad(i) {
                        Color.clear
                            .frame(width: 28, height: 38)
                            .id(i)
                    } else {
                        let date = date(for: i)
                        DayCell(
                            date: date,
                            isSelected: Foundation.Calendar.current.isDate(date, inSameDayAs: selected),
                            isToday: Foundation.Calendar.current.isDateInToday(date)
                        )
                        .id(i)
                        .onTapGesture {
                            programmaticScroll = true
                            withAnimation { scrollPosition = i }
                            onSelect(date)
                            Haptics.tap()
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .onAppear { centerOnSelected() }
        .onChange(of: selected) { _, _ in centerOnSelected() }
        .onChange(of: scrollPosition) { _, new in
            guard !programmaticScroll else {
                programmaticScroll = false
                return
            }
            guard let i = new, !isPad(i) else { return }
            let d = date(for: i)
            if !Foundation.Calendar.current.isDate(d, inSameDayAs: selected) {
                onSelect(d)
                Haptics.tap()
            }
        }
    }

    private func isPad(_ i: Int) -> Bool {
        i < Self.pad || i >= Self.pad + totalDays
    }

    private func date(for i: Int) -> Date {
        let cal = Foundation.Calendar.current
        let start = cal.date(byAdding: .day, value: -Self.pastDays, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(byAdding: .day, value: i - Self.pad, to: start) ?? start
    }

    private func index(for date: Date) -> Int {
        let cal = Foundation.Calendar.current
        let start = cal.date(byAdding: .day, value: -Self.pastDays, to: cal.startOfDay(for: Date())) ?? Date()
        let days = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? 0
        return max(0, min(totalDays - 1, days)) + Self.pad
    }

    private func centerOnSelected() {
        let target = index(for: selected)
        if scrollPosition != target {
            programmaticScroll = true
            withAnimation { scrollPosition = target }
        }
    }
}

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
            ZStack {
                if isToday {
                    Circle().fill(Color.accentColor).frame(width: 22, height: 22)
                }
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : (isToday ? Color.white : Color.white.opacity(0.65))
                    )
            }
            .frame(width: 22, height: 22)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .frame(height: 38)
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Calendar color bar on the leading edge — at-a-glance source
            // hint matching boring.notch's design.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "(no title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("All-day")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    Text(event.startDate, style: .time)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(event.endDate, style: .time)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
        }
        .opacity(isEnded ? 0.55 : 1.0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            // Open in Calendar.app using the event's persistent URL.
            if let url = URL(string: "ical://ekevent/\(event.eventIdentifier ?? "")") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var isEnded: Bool {
        !event.isAllDay
            && event.endDate < Date()
            && Foundation.Calendar.current.isDateInToday(event.startDate)
    }
}
