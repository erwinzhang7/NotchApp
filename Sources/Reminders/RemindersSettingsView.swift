import EventKit
import SwiftUI

/// Settings UI: single-select list picker. "Scheduled" (default, nil
/// selection) shows every incomplete reminder with a due date; picking a
/// specific list narrows the view to that one.
struct RemindersSettingsView: View {
    @ObservedObject var service: RemindersService
    @ObservedObject var settings: RemindersSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick which list shows in the Ambient tab. \"Scheduled\" includes every incomplete reminder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch service.accessStatus {
            case .fullAccess:
                listPicker
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

    private var listPicker: some View {
        Picker("List", selection: selectionBinding) {
            Text("Scheduled (all)").tag(String?.none)
            Divider()
            ForEach(service.availableLists, id: \.calendarIdentifier) { cal in
                Text(cal.title).tag(Optional(cal.calendarIdentifier))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 280)
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { settings.selectedListID },
            set: { settings.selectedListID = $0 }
        )
    }

    private var permissionPrompt: some View {
        HStack(spacing: 8) {
            Text("Reminders access not yet granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Request Access") {
                Task { await service.requestAccess() }
            }
            .controlSize(.small)
        }
    }

    private var deniedHint: some View {
        Text("Reminders access was denied. Enable it in System Settings → Privacy & Security → Reminders.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
