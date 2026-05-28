import SwiftUI
import UniformTypeIdentifiers

/// Drop-target tile that fires AirDrop with whatever files are dropped onto
/// it. Used in both shelf layouts (shrunken square next to the slot,
/// strip-height square at the head of the full strip). Drops here do NOT
/// add to the shelf — the tile is a pure pass-through to system AirDrop.
struct AirDropTileView: View {
    enum Layout {
        /// Square 160×160 — matches `compactSlot` in shrunken shelf.
        case large
        /// Square sized to the strip's tile row (64×64).
        case strip
    }

    let layout: Layout
    @State private var isTargeted = false

    private var side: CGFloat {
        switch layout {
        case .large: return 160
        case .strip: return 64
        }
    }

    private var iconSize: CGFloat {
        switch layout {
        case .large: return 38
        case .strip: return 22
        }
    }

    var body: some View {
        ZStack {
            // Highlight background while targeted. Matches the strip's
            // accent-tinted drop feedback so the two read as one system.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))

            VStack(spacing: layout == .large ? 6 : 3) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.85))
                Text("AirDrop")
                    .font(layout == .large ? .caption.weight(.semibold) : .system(size: 9, weight: .semibold))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.7))
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [4, 3] : [])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("Drop a file here to send via AirDrop")
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Haptics.tap()
            AirDropService.send(urls)
        }
        return true
    }
}
