import SwiftUI

/// Tabs presented on either side of the physical notch when the panel is expanded.
/// - `clip`: clipboard history (implemented, default).
/// - `ambient`: reserved for future modules — media controls, file shelf, etc.
enum NotchTab: Hashable {
    case ambient
    case clip

    var title: String {
        switch self {
        case .ambient: return "Ambient"
        case .clip:    return "Clip"
        }
    }
}

/// Small pill label rendered inside one of the side strips beside the notch.
/// Purely visual — the surrounding tap targets live in NotchShellView so this view
/// itself does not capture clicks (it sits under `.allowsHitTesting(false)`).
struct TabLabelView: View {
    let tab: NotchTab
    let selected: Bool

    var body: some View {
        Text(tab.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(selected ? Color.white.opacity(0.16) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

/// Stand-in for the left (Ambient) tab until media controls / file shelf land.
struct NotchAmbientPlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Reserved for future modules")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Media controls, file shelf, and other ambient surfaces will live here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
