import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Horizontal strip of held files, shown above the clipboard history when the shelf has
/// contents or while a drag is being targeted at the panel. The strip itself is a
/// drop zone, but the *real* drop catcher lives on the panel root so dragging works
/// while collapsed too.
struct FileShelfStripView: View {
    @ObservedObject var store: FileShelfStore
    /// Whether a drag is currently being targeted at the panel (from NotchState).
    var isTargeted: Bool
    /// Transient banner above the strip when a conversion errored.
    @ObservedObject private var conversion = ConversionManager.shared.service

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = conversion.lastError {
                errorBanner(error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            header
            tiles
        }
        .animation(.easeInOut(duration: 0.18), value: conversion.lastError)
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                conversion.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
        )
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
            convertMenuItems()
            Button("Reveal in Finder") {
                if let url = store.resolvedURL(for: item) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Remove", role: .destructive) { store.remove(item) }
        }
        .help(item.displayName)
    }

    /// Convert-to entries — only shown when the registry actually has
    /// valid output targets for this file's UTType (which itself respects
    /// the category toggles in ConversionSettings). The one-click default
    /// is hidden if the default format equals the file's current type or
    /// isn't a valid target for it; in that case only the submenu shows.
    @ViewBuilder
    private func convertMenuItems() -> some View {
        if let inputType = item.utType {
            let manager = ConversionManager.shared
            let outputs = manager.registry.outputs(for: inputType)
            if !outputs.isEmpty {
                let defaultType = manager.settings.defaultOutputUTType
                let showDefault = outputs.contains(defaultType) && defaultType != inputType
                if showDefault {
                    Button("Convert to \(ImageFormat.displayName(for: defaultType))") {
                        Task { await manager.service.convert(item: item, to: defaultType) }
                    }
                }
                Menu("Convert to") {
                    ForEach(outputs.filter { showDefault ? $0 != defaultType : true },
                            id: \.identifier) { target in
                        Button(ImageFormat.displayName(for: target)) {
                            Task { await manager.service.convert(item: item, to: target) }
                        }
                    }
                }
                Divider()
            }
        }
    }
}
