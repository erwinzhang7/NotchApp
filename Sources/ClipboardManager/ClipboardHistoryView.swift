import AppKit
import SwiftUI

/// Most-recent-first list of captured clipboard items.
/// Click a row → re-copies it to the system pasteboard + brief "Copied!" flash.
/// Right-click for Remove. Mounted both inside the notch shell's expanded panel and
/// in the standalone history window.
struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore

    /// Called immediately after a successful paste-on-select. The notch shell uses this to
    /// hold the panel open long enough for the feedback flash to render. Defaults to no-op
    /// so the standalone history window doesn't need to wire anything.
    var onCopy: (() -> Void)? = nil

    /// ID of the item that was just copied; drives the per-row feedback flash.
    @State private var lastCopiedID: ClipboardItem.ID?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(minWidth: 240, minHeight: 200)
        // Pure black so the clipboard surface matches the notch / tab
        // strip without the .bar / system-list grey breaking the tone.
        .background(Color.black)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history", text: $store.searchQuery)
                .textFieldStyle(.plain)
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Was .bar (system grey toolbar material). Pure black to match.
        .background(Color.black)
    }

    @ViewBuilder
    private var content: some View {
        let visible = store.filteredItems
        if visible.isEmpty {
            EmptyClipStateView(searchQuery: store.searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            List {
                ForEach(visible) { item in
                    // Button (plain style) instead of onTapGesture: SwiftUI
                    // List on macOS swallows single taps from .onTapGesture
                    // for its own row-selection handling, so a plain click
                    // never reached copy(). Buttons take a different event
                    // path that the List honors on the first click.
                    Button {
                        copy(item)
                    } label: {
                        ClipboardRowView(item: item, isJustCopied: lastCopiedID == item.id)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Copy") { copy(item) }
                        Button("Remove", role: .destructive) { store.remove(item) }
                    }
                    // Per-row clear background so the only fill is
                    // the row's own justCopied green flash; List's
                    // default row tint can't peek through.
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            // Hide List's own scroll-content background (the grey that
            // was previously bleeding through under the rows).
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }

    /// Writes the item back to the pasteboard, flashes a per-row "Copied!" indicator, and
    /// signals the host (notch shell) to keep the surface up long enough for the flash.
    /// The store's lastInternalChangeCount tracking prevents the monitor from re-capturing
    /// this as a fresh entry.
    private func copy(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        onCopy?()

        // Drive the feedback through plain @State + per-row .animation(value:) rather than
        // .transition() — opacity-gated, always-rendered views diff reliably even when the
        // parent is animating (spring expansion, tab switching, etc.).
        feedbackTask?.cancel()
        lastCopiedID = item.id

        let target = item.id
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }
            if lastCopiedID == target {
                lastCopiedID = nil
            }
        }
    }
}

/// One row. Renders a text preview / image thumbnail / file icon + name based on the kind.
/// When `isJustCopied` is true, the row paints a full-row green tint and shows a
/// "✓ Copied!" badge in the trailing position. Badge and tint are ALWAYS in the view tree;
/// opacity gates them so the diff is reliable and the animation always paints.
struct ClipboardRowView: View {
    let item: ClipboardItem
    var isJustCopied: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                primary
                    .lineLimit(2)
                    .font(.body)
                Text(item.capturedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            copiedBadge
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green)
                .opacity(isJustCopied ? 0.28 : 0)
        )
        .animation(.easeOut(duration: 0.18), value: isJustCopied)
    }

    /// Always rendered; opacity + scale gate visibility so the row's body diff is reliable.
    private var copiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text("Copied!")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.green)
        .opacity(isJustCopied ? 1 : 0)
        .scaleEffect(isJustCopied ? 1 : 0.85, anchor: .trailing)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let payload):
            Image(nsImage: payload.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(4)
        case .files(let payload):
            if let icon = payload.files.first?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch item.kind {
        case .text(let s):
            Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .image(let payload):
            let size = payload.image.size
            Text("Image · \(Int(size.width))×\(Int(size.height))")
        case .files(let payload):
            if payload.files.count == 1, let f = payload.files.first {
                Text(f.displayName)
            } else if let first = payload.files.first {
                Text("\(first.displayName) +\(payload.files.count - 1) more")
            } else {
                Text("Files")
            }
        }
    }
}
