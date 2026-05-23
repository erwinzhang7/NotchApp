import SwiftUI

/// Placeholder content rendered inside the notch panel until feature modules land.
struct NotchShellView: View {
    var body: some View {
        // A dark rounded rectangle that visually blends with the notch so the
        // panel position can be verified across displays. Real content will
        // replace this once FileShelf / MediaControls / ClipboardManager exist.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black)
            .ignoresSafeArea()
    }
}
