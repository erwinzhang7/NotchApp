import AppKit
import SwiftUI

/// Horizontal strip of held files, shown above the clipboard history when the shelf has
/// contents or while a drag is being targeted at the panel. The strip itself is a
/// drop zone, but the *real* drop catcher lives on the panel root so dragging works
/// while collapsed too.
struct FileShelfStripView: View {
    @ObservedObject var store: FileShelfStore
    /// Whether a drag is currently being targeted at the panel (from NotchState).
    var isTargeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            tiles
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isTargeted ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [4, 3] : [])
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isTargeted)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.to.line.compact" : "tray.full")
            Text(headerTitle)
            Spacer(minLength: 0)
            if !store.items.isEmpty {
                Button {
                    store.clearAll()
                } label: {
                    Text("Clear")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
    }

    @ViewBuilder
    private var tiles: some View {
        if store.items.isEmpty {
            // No held files yet — show drop hint inline at fixed height so the strip
            // doesn't jump in size when the first file is added.
            HStack {
                Spacer()
                Text(isTargeted ? "Release to drop" : "Drop files here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 64)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.items) { item in
                        FileShelfTileView(item: item, store: store)
                    }
                }
            }
            .frame(height: 64)
        }
    }

    private var headerTitle: String {
        if isTargeted { return "Drop to shelf" }
        let n = store.items.count
        if n == 0 { return "Shelf" }
        if n == 1 { return "1 file held" }
        return "\(n) files held"
    }
}

/// Single tile in the shelf strip. Draggable back out to Finder / other apps via an
/// NSItemProvider built from the bookmark-resolved file URL.
struct FileShelfTileView: View {
    let item: FileShelfItem
    @ObservedObject var store: FileShelfStore
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)

                if hovering {
                    Button {
                        store.remove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.opacity)
                }
            }
            Text(item.displayName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .frame(width: 72)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .onDrag {
            // Resolve through the bookmark so a moved file still drags correctly.
            let url = store.resolvedURL(for: item) ?? item.url
            return NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                if let url = store.resolvedURL(for: item) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Remove", role: .destructive) { store.remove(item) }
        }
        .help(item.displayName)
    }
}
