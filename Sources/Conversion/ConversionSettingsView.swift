import SwiftUI

/// Settings tab for the Conversion feature. Toggles for the two
/// categories, the default output format, and the destructive
/// "Delete original after conversion" switch.
struct ConversionSettingsView: View {
    @ObservedObject private var settings = ConversionManager.shared.settings

    var body: some View {
        Form {
            Section("Categories") {
                Toggle("Image conversion", isOn: $settings.isImageConversionEnabled)
                Toggle("Document conversion (PDF ↔ image)", isOn: $settings.isDocumentConversionEnabled)
                Text("Disable a category to hide its options from the shelf's right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default output") {
                Picker("Default format", selection: $settings.defaultOutputFormat) {
                    // Only formats the launch-time encoding self-test
                    // confirmed this system can write. Formats ImageIO
                    // can't encode (e.g. WebP on some macOS builds) are
                    // hidden so the user can't pick something that would
                    // silently fail.
                    ForEach(ImageEncodingCapability.writableFormats) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text("Used by the one-click \"Convert to …\" item. The submenu still offers every other valid target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Source file") {
                Toggle("Delete original after conversion", isOn: $settings.deleteOriginalAfterConversion)
                Text("Off (default): both files are kept side by side. On: the original is removed and its shelf entry is replaced by the converted file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
