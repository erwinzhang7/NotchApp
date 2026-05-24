import AppKit
import EventKit
import SwiftUI

/// Glance view: scheduled reminders, soonest first. Tap a row to mark
/// complete (it disappears from the list). Permission states handled
/// inline like the calendar view.
struct RemindersView: View {
    @ObservedObject var service: RemindersService
    @ObservedObject var settings: RemindersSettings

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
            Image(systemName: "checklist")
                .font(.system(size: 10, weight: .semibold))
            Text(listLabel)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private var listLabel: String {
        if let id = settings.selectedListID,
           let cal = service.availableLists.first(where: { $0.calendarIdentifier == id }) {
            return cal.title
        }
        return "Scheduled"
    }

    @ViewBuilder
    private var content: some View {
        switch service.accessStatus {
        case .fullAccess:
            remindersList
        case .notDetermined:
            permissionPrompt
        case .denied, .restricted, .writeOnly:
            deniedHint
        @unknown default:
            deniedHint
        }
    }

    @ViewBuilder
    private var remindersList: some View {
        if service.scheduledReminders.isEmpty {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Nothing scheduled.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(service.scheduledReminders, id: \.calendarItemIdentifier) { reminder in
                        ReminderRow(reminder: reminder) {
                            service.markComplete(reminder)
                        }
                    }
                }
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 6) {
            Text("NotchApp needs reminders access to show your list.")
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
            Text("Reminders access denied")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                openRemindersPrivacySettings()
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openRemindersPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ReminderRow: View {
    let reminder: EKReminder
    let onComplete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onComplete) {
                Image(systemName: hovering ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title ?? "(no title)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                if let dueText = dueText {
                    Text(dueText)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(dueIsPast ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .onHover { hovering = $0 }
    }

    private var dueText: String? {
        guard let date = reminder.resolvedDueDate else { return nil }
        let formatter = DateFormatter()
        if Foundation.Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return "Today, " + formatter.string(from: date)
        } else if Foundation.Calendar.current.isDateInTomorrow(date) {
            formatter.dateFormat = "h:mm a"
            return "Tomorrow, " + formatter.string(from: date)
        } else {
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    private var dueIsPast: Bool {
        guard let date = reminder.resolvedDueDate else { return false }
        return date < Date()
    }
}
