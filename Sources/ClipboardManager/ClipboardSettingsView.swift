import SwiftUI

/// Pane mounted under the SwiftUI Settings scene (Cmd+,).
/// Holds the auto-clear interval, per-type capture toggles, and a Clear-history-now action.
struct ClipboardSettingsView: View {
    @ObservedObject var settings: ClipboardSettings
    @ObservedObject var store: ClipboardStore

    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Auto-clear") {
                Picker("Clear history after", selection: $settings.autoClearInterval) {
                    ForEach(ClipboardSettings.AutoClearInterval.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Button("Clear history now…") {
                    confirmClear = true
                }
                .confirmationDialog(
                    "Clear all clipboard history?",
                    isPresented: $confirmClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear", role: .destructive) { store.clearAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") will be removed.")
                }
            }

            Section("Capture") {
                Toggle("Text", isOn: $settings.captureText)
                Toggle("Images", isOn: $settings.captureImages)
                Toggle("File copies", isOn: $settings.captureFiles)
            }

            Section {
                Text("Clipboard history is kept in memory only and is never written to disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
