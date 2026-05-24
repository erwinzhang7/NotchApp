import EventKit
import SwiftUI

/// Glance view: today's remaining calendar events. Compact list — time +
/// title per row. Handles the EventKit permission states inline (grant /
/// denied hints) so the dashboard never shows a blank panel.
struct CalendarView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var settings: CalendarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
            Text("Today")
                .font(.system(size: 10, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch service.accessStatus {
        case .fullAccess:
            eventsList
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
    private var eventsList: some View {
        let remaining = remainingEvents
        if remaining.isEmpty {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No more events today!")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(remaining, id: \.eventIdentifier) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }

    private var remainingEvents: [EKEvent] {
        let now = Date()
        return service.todaysEvents.filter { $0.endDate >= now }
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
                openCalendarPrivacySettings()
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Color dot for the event's calendar — at-a-glance source hint.
            Circle()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(timeString)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.title ?? "(no title)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
    }

    private var timeString: String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: event.startDate)
    }
}
