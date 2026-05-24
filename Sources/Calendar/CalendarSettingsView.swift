import EventKit
import SwiftUI

/// Settings UI: multi-select calendar picker. Default state is "no
/// selection" which the service treats as "all calendars".
struct CalendarSettingsView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var settings: CalendarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose which calendars show in the Ambient tab. Leave all unchecked to include everything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch service.accessStatus {
            case .fullAccess:
                calendarList
            case .notDetermined:
                permissionPrompt
            case .denied, .restricted, .writeOnly:
                deniedHint
            @unknown default:
                deniedHint
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Replaced the previous `List` with a ScrollView+VStack: List inside
    /// a Form (which Settings wraps in NSScrollView) was triggering the
    /// AppKit layout-recursion guard.
    private var calendarList: some View {
        Group {
            if service.availableCalendars.isEmpty {
                Text("No calendars found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(service.availableCalendars, id: \.calendarIdentifier) { cal in
                            Toggle(isOn: binding(for: cal)) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(nsColor: cal.color))
                                        .frame(width: 8, height: 8)
                                    Text(cal.title)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func binding(for cal: EKCalendar) -> Binding<Bool> {
        let id = cal.calendarIdentifier
        return Binding(
            get: { settings.selectedCalendarIDs.contains(id) },
            set: { isOn in
                if isOn {
                    settings.selectedCalendarIDs.insert(id)
                } else {
                    settings.selectedCalendarIDs.remove(id)
                }
            }
        )
    }

    private var permissionPrompt: some View {
        HStack(spacing: 8) {
            Text("Calendar access not yet granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Request Access") {
                Task { await service.requestAccess() }
            }
            .controlSize(.small)
        }
    }

    private var deniedHint: some View {
        Text("Calendar access was denied. Enable it in System Settings → Privacy & Security → Calendars.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
