import SwiftUI
import UniformTypeIdentifiers

/// Notch surface: collapsed pill at rest, springs open on hover, pins open on chrome click.
/// When expanded, a two-tab strip flanks the physical notch and the selected module fills
/// the area below. The outermost view is a panel-wide drop catcher so dragging a file
/// toward the notch — even while collapsed — expands the shell and lands on the same
/// drop handler.
struct NotchShellView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var layout: NotchLayoutModel

    @AppStorage("notch.selectedTab") private var selectedTab: NotchTab = .ambient
    @ObservedObject private var appSettings = AmbientSettings.shared

    /// Keep NotchState.selectedTab synchronized with the @AppStorage value so
    /// NotchWindowController can re-size the panel on tab switch — the
    /// controller observes NotchState, not UserDefaults.
    private func syncTabToState() {
        if state.selectedTab != selectedTab { state.selectedTab = selectedTab }
    }

    /// Must stay in sync with NotchGeometry.hoverSlop.
    private let hoverSlop: CGFloat = 5

    var body: some View {
        let isExpanded = state.isExpanded
        let size = isExpanded ? layout.expandedSize : layout.collapsedSize
        let bottomCornerRadius: CGFloat = 10
        // Lateral extension at the top corners — the shape canvas grows by
        // this much on each side, the body width (hitbox) stays the same.
        let topSweep: CGFloat = 12
        let hitWidth = size.width + hoverSlop * 2
        let hitHeight = size.height + hoverSlop
        let canvasWidth = size.width + topSweep * 2
        let notchReserveHeight = layout.collapsedSize.height
        let notchReserveWidth = layout.collapsedSize.width

        let panelShape = NotchPanelShape(
            topSweep: topSweep,
            bottomConvexRadius: bottomCornerRadius
        )

        ZStack(alignment: .top) {
            // Invisible hover/tap target sized slightly larger than the visible surface.
            Color.clear
                .frame(width: hitWidth, height: hitHeight)

            // Visible surface + expanded content. Fill and border are
            // opacity-gated on isExpanded — collapsed renders nothing
            // visible at all (no pill, no background, no border) so the
            // notch area looks empty when at rest. The hit zone above,
            // the global hover monitor, .onTapGesture and the panel-wide
            // .onDrop are all unaffected — hover-to-expand, click-to-pin,
            // and drag-to-reveal still trigger from the invisible region.
            // Opacity rather than `if isExpanded` so the spring animation
            // fades the surface in/out smoothly with the size change.
            ZStack {
                // Fill spans the expanded canvas so the swept top corners
                // render outside the body width into the breathing room
                // area (which is already part of the NSPanel frame).
                panelShape.fill(Color.black)
                    .frame(width: canvasWidth, height: size.height)
                    .opacity(isExpanded ? 1 : 0)

                if isExpanded {
                    expandedContent(
                        notchHeight: notchReserveHeight,
                        notchWidth: notchReserveWidth
                    )
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
                }
            }
            .frame(width: canvasWidth, height: size.height)
            // Clip tab contents to the panel outline. Without this, child
            // views that paint their own rectangular backgrounds (e.g. the
            // Clip tab's Color.black layers) bleed past the swept top
            // corners and the rounded bottom corners.
            .clipShape(panelShape)
            // Border on left / right / bottom only. The top edge would look like a seam
            // against the screen top, so we mask the top 1.5pt of the stroke out — the
            // tiny gap at the very top of the L/R edges falls behind the physical notch
            // on notched displays.
            .overlay(
                panelShape
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: canvasWidth, height: size.height)
                    .mask(
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 1.5)
                            Rectangle()
                        }
                    )
                    .opacity(isExpanded ? 1 : 0)
            )
        }
        .contentShape(Rectangle())
        // Hover is detected by NotchWindowController's global mouse-moved
        // monitor (see EventMonitor + handleMouseMoved). SwiftUI .onHover here
        // would fire inside the SwiftUI layout pass and re-trigger the
        // panel-resize sink during layout, which AppKit forbids.
        .onTapGesture { state.togglePinned() }
        // Right-click anywhere on the visible notch surface for the launcher
        // menu. With the menu-bar icon hidden, this is the user's path
        // back to Settings and to re-showing the icon.
        .contextMenu { notchContextMenu }
        // Same easing as NotchWindowController's window-frame animation so the
        // SwiftUI content edge and the NSPanel edge advance together — no
        // gap above or below the panel mid-animation.
        .animation(.easeOut(duration: 0.32), value: isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The panel window's top edge sits flush with the screen top. Without
        // this, SwiftUI's automatic top safe-area inset (notch height) pushes
        // the content down and leaves a visible gap above the panel.
        .ignoresSafeArea(.all, edges: .top)
        .onAppear { syncTabToState() }
        .onChange(of: selectedTab) { _, _ in syncTabToState() }
        // Panel-wide drop catcher. The NSPanel frame is always sized for the expanded
        // surface + slop (~528×424), so this drop zone exists whether or not the SwiftUI
        // content is currently in its collapsed pill — that's how a drag toward a
        // collapsed notch triggers expansion in one motion.
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isDragTargeted) { providers in
            selectedTab = .clip
            Task { @MainActor in
                await FileShelf.shared.store.accept(providers: providers)
                // Keep the panel open briefly after drop so the user sees the file land
                // in the shelf even if their cursor has already left the panel.
                state.holdOpen(for: .milliseconds(1500))
            }
            return true
        }
    }

    /// Right-click launcher menu. Mirrors the menu-bar icon's items so
    /// the user can still reach Settings / History / quit with the icon
    /// hidden, plus a checkable "Show in Menu Bar" to bring it back.
    @ViewBuilder
    private var notchContextMenu: some View {
        Button("Open Settings…") {
            (NSApp.delegate as? AppDelegate)?.openSettings()
        }
        Button("Show Clipboard History") {
            (NSApp.delegate as? AppDelegate)?.showHistory()
        }
        Toggle("Show in Menu Bar", isOn: $appSettings.showInMenuBar)
        Divider()
        Button("Quit NotchApp") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private func expandedContent(notchHeight: CGFloat, notchWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            tabStrip(notchHeight: notchHeight, notchWidth: notchWidth)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    /// Two tabs sitting at notch level. CLICK regions are a full 50/50 split of the panel
    /// width; visible labels are constrained to the side strips beside the notch.
    @ViewBuilder
    private func tabStrip(notchHeight: CGFloat, notchWidth: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTab = .ambient }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTab = .clip }
            }

            HStack(spacing: 0) {
                TabLabelView(tab: .ambient, selected: selectedTab == .ambient)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Color.clear
                    .frame(width: notchWidth)
                TabLabelView(tab: .clip, selected: selectedTab == .clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .allowsHitTesting(false)
        }
        .frame(height: notchHeight)
    }

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .ambient:
                AmbientDashboardView()
            case .clip:
                ClipTabContent(
                    clipboardStore: ClipboardManager.shared.store,
                    shelfStore: FileShelf.shared.store,
                    isDragTargeted: state.isDragTargeted,
                    onCopy: { state.holdOpen(for: .milliseconds(1200)) }
                )
            }
        }
        .id(selectedTab)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: selectedTab)
    }
}

/// Composition view for the Clip tab: file shelf strip (when visible) above the
/// clipboard history. The shelf strip slides in / out as items appear / disappear or
/// as a drag is targeted at the panel.
struct ClipTabContent: View {
    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var shelfStore: FileShelfStore
    @ObservedObject private var ambient = AmbientSettings.shared
    var isDragTargeted: Bool
    var onCopy: () -> Void

    /// The Ambient pane shrinks to music-only when both bottom toggles are
    /// off; the Clip tab inherits that height. In shrunk mode there isn't
    /// room for a search field or a horizontal shelf strip, so the layout
    /// switches to a single left-aligned file slot (capacity 1, drag-out
    /// supported) + the bare clipboard list.
    private var isShrunk: Bool {
        !ambient.showCalendar && !ambient.showReminders
    }

    private var shelfVisible: Bool { shelfStore.hasItems || isDragTargeted }

    var body: some View {
        if isShrunk {
            shrunkBody
        } else {
            fullBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            if shelfVisible {
                FileShelfStripView(store: shelfStore, isTargeted: isDragTargeted)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ClipboardHistoryView(store: clipboardStore, onCopy: onCopy)
        }
        .animation(.easeInOut(duration: 0.22), value: shelfVisible)
    }

    private var shrunkBody: some View {
        HStack(spacing: 0) {
            if shelfStore.hasItems || isDragTargeted {
                compactSlot
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                    .transition(.opacity)
            }
            ClipboardHistoryView(
                store: clipboardStore,
                onCopy: onCopy,
                showSearch: false
            )
        }
        .animation(.easeInOut(duration: 0.22), value: shelfStore.hasItems)
        .animation(.easeInOut(duration: 0.22), value: isDragTargeted)
    }

    /// Single-file slot used in the shrunk Clip layout. Square: width
    /// equals the available content height (= NotchWindowController's
    /// ambientMusicHeight, 160). Thumbnail of the top-of-stack file
    /// centered inside; empty drag-target shows a drop hint. Drag-out +
    /// remove-on-hover come from FileShelfTileView itself.
    @ViewBuilder
    private var compactSlot: some View {
        ZStack {
            if isDragTargeted {
                Color.white.opacity(0.08)
            }
            if let topItem = shelfStore.items.last {
                FileShelfTileView(item: topItem, store: shelfStore)
            } else if isDragTargeted {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 22))
                    Text("Drop")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
            }
        }
        // 160 matches NotchWindowController.ambientMusicHeight so the
        // slot is a true square against the available vertical space.
        .frame(width: 160, height: 160)
    }
}
