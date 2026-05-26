import SwiftUI

/// Root settings scene — tabbed across modules.
struct SettingsView: View {
    @State private var tab: SettingsTab = .ambient

    var body: some View {
        VStack(spacing: 0) {
            // Segmented picker lives in the content area so it sits below
            // the title bar rather than colliding with it.
            Picker("", selection: $tab) {
                Text("Ambient").tag(SettingsTab.ambient)
                Text("Clipboard").tag(SettingsTab.clipboard)
                Text("Conversion").tag(SettingsTab.conversion)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .clipboard:
                    ClipboardSettingsView(
                        settings: ClipboardManager.shared.settings,
                        store: ClipboardManager.shared.store
                    )
                case .ambient:
                    AmbientSettingsView()
                case .conversion:
                    ConversionSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 540)
    }
}

private enum SettingsTab { case clipboard, ambient, conversion }

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

            Section("Lock Screen Music Widget") {
                Toggle("Show music on lock screen", isOn: $ambient.lockScreenWidgetEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vertical position")
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: $ambient.lockScreenWidgetVerticalOffset,
                            in: -100...100
                        )
                        Image(systemName: "arrow.down")
                            .foregroundStyle(.secondary)
                        Button("Center") {
                            ambient.lockScreenWidgetVerticalOffset = 0
                        }
                        .disabled(ambient.lockScreenWidgetVerticalOffset == 0)
                    }
                }
                .disabled(!ambient.lockScreenWidgetEnabled)
                Toggle("Show lyrics when artwork is enlarged", isOn: $ambient.showLockScreenLyrics)
                    .disabled(!ambient.lockScreenWidgetEnabled)
                Text("Synced lyrics from LRCLIB appear to the right of the lifted artwork. Only fetched while this is on. Compact view is unchanged. Toggle lyrics in the notch by clicking the artwork.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Small music card centered horizontally above the lock screen and shown when the Mac is idle. Hidden while you're using the Mac (or while caffeinate / similar is keeping it awake). Uses a private macOS API and may break in future macOS updates.")
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

