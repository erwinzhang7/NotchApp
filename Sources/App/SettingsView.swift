import SwiftUI

/// Root settings scene — tabbed across modules. Existing clipboard pane
/// stays as-is; new Ambient pane bundles the dashboard toggles, calendar
/// picker, and reminders list picker.
struct SettingsView: View {
    var body: some View {
        TabView {
            ClipboardSettingsView(
                settings: ClipboardManager.shared.settings,
                store: ClipboardManager.shared.store
            )
            .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }

            AmbientSettingsView()
                .tabItem { Label("Ambient", systemImage: "rectangle.on.rectangle") }

            ConversionSettingsView()
                .tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520, height: 520)
    }
}

/// Ambient pane: toggles for the optional bottom row + the calendar /
/// reminders pickers. Built as a Form (matching ClipboardSettingsView) —
/// nested ScrollView/List caused the AppKit layout-recursion warning that
/// blocked the settings window from rendering cleanly.
struct AmbientSettingsView: View {
    @ObservedObject private var ambient = AmbientSettings.shared
    @ObservedObject private var calendarService  = CalendarManager.shared.service
    @ObservedObject private var calendarSettings = CalendarManager.shared.settings
    @ObservedObject private var remindersService  = RemindersManager.shared.service
    @ObservedObject private var remindersSettings = RemindersManager.shared.settings

    var body: some View {
        Form {
            Section("Dashboard") {
                Toggle("Show Calendar", isOn: $ambient.showCalendar)
                Toggle("Show Reminders", isOn: $ambient.showReminders)
                Text("Music is always shown. Both off → panel shrinks to music-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendars") {
                CalendarSettingsView(
                    service: calendarService,
                    settings: calendarSettings
                )
            }

            Section("Reminders") {
                RemindersSettingsView(
                    service: remindersService,
                    settings: remindersSettings
                )
            }
        }
        .formStyle(.grouped)
    }
}
