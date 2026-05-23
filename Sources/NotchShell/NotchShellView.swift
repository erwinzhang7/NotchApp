import SwiftUI
import UniformTypeIdentifiers

/// Notch surface: collapsed pill at rest, springs open on hover, pins open on chrome click.
/// When expanded, a two-tab strip flanks the physical notch and the selected module fills
/// the area below. The outermost view is a panel-wide drop catcher so dragging a file
/// toward the notch — even while collapsed — expands the shell and lands on the same
/// drop handler.
struct NotchShellView: View {
    @ObservedObject var state: NotchState
    let collapsedSize: CGSize
    let expandedSize: CGSize

    @State private var selectedTab: NotchTab = .clip

    /// Must stay in sync with NotchGeometry.hoverSlop.
    private let hoverSlop: CGFloat = 8

    var body: some View {
        let isExpanded = state.isExpanded
        let size = isExpanded ? expandedSize : collapsedSize
        let pillRadius = min(collapsedSize.height / 2, 16)
        // Top corners go to zero when expanded so the panel sits flush against the notch /
        // top edge of the screen. Bottom corners stay generously rounded.
        let topRadius: CGFloat = isExpanded ? 0 : pillRadius
        let bottomRadius: CGFloat = isExpanded ? 24 : pillRadius
        let hitWidth = size.width + hoverSlop * 2
        let hitHeight = size.height + hoverSlop
        let notchReserveHeight = collapsedSize.height
        let notchReserveWidth = collapsedSize.width

        let panelShape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        )

        ZStack(alignment: .top) {
            // Invisible hover/tap target sized slightly larger than the visible surface.
            Color.clear
                .frame(width: hitWidth, height: hitHeight)

            // Visible surface + expanded content.
            ZStack {
                panelShape.fill(Color.black)

                if isExpanded {
                    expandedContent(
                        notchHeight: notchReserveHeight,
                        notchWidth: notchReserveWidth
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(panelShape)
            // Border on left / right / bottom only. The top edge would look like a seam
            // against the screen top, so we mask the top 1.5pt of the stroke out — the
            // tiny gap at the very top of the L/R edges falls behind the physical notch
            // on notched displays.
            .overlay(
                panelShape
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    .mask(
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 1.5)
                            Rectangle()
                        }
                    )
            )
        }
        .contentShape(Rectangle())
        // Hover is detected by NotchWindowController's global mouse-moved
        // monitor (see EventMonitor + handleMouseMoved). SwiftUI .onHover here
        // would fire inside the SwiftUI layout pass and re-trigger the
        // panel-resize sink during layout, which AppKit forbids.
        .onTapGesture { state.togglePinned() }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    @ViewBuilder
    private func expandedContent(notchHeight: CGFloat, notchWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            tabStrip(notchHeight: notchHeight, notchWidth: notchWidth)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

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
                NotchAmbientPlaceholderView()
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
    var isDragTargeted: Bool
    var onCopy: () -> Void

    private var shelfVisible: Bool { shelfStore.hasItems || isDragTargeted }

    var body: some View {
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
}
