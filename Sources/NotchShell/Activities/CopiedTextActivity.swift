import AppKit
import Combine
import SwiftUI

/// Drops a "Copied N characters" pill BELOW the physical notch when the
/// auto-copy-on-selection feature fires. Independent NSPanel — lives
/// completely separate from `IdleNotchPillController`'s always-visible
/// pill so the now-playing / brightness / volume activities up at the
/// notch keep rendering uninterrupted while this banner is on screen.
///
/// Lifecycle: AppDelegate calls `show(characterCount:lineCount:)` when
/// `ClipboardManager.selectionCopiedEvents` fires (and we're not locked).
/// The banner slides down + fades in, holds, then slides up + fades out.
@MainActor
final class CopyBannerController {
    /// How long the banner stays at full opacity before fading out.
    private static let holdDuration: TimeInterval = 1.4
    /// Slide + fade transition timing.
    private static let transitionDuration: TimeInterval = 0.22
    /// Gap between the bottom of the notch and the top of the banner pill.
    private static let gapBelowNotch: CGFloat = 4
    /// Banner pill height. Matches the idle pill height for visual rhyme.
    private static let bannerHeight: CGFloat = 32
    /// Min / max width — banner sizes to label content, clamped here so
    /// it never disappears or sprawls. 220pt fits the longest expected
    /// string ("Copied 9999 lines" ≈ 138pt at the chosen font + chrome).
    private static let minWidth: CGFloat = 140
    private static let maxWidth: CGFloat = 260

    private var panel: NSPanel?
    private var content = BannerContent()
    private var hideTask: Task<Void, Never>?

    func show(characterCount: Int, lineCount: Int) {
        let label: String
        if characterCount < 1000 {
            let word = characterCount == 1 ? "character" : "characters"
            label = "Copied \(characterCount) \(word)"
        } else {
            let word = lineCount == 1 ? "line" : "lines"
            label = "Copied \(lineCount) \(word)"
        }

        buildPanelIfNeeded()
        guard let panel else { return }

        // Resize panel to fit current label.
        let width = Self.measureWidth(for: label)
        if let frame = panelFrame(width: width) {
            panel.setFrame(frame, display: true)
        }

        content.label = label
        // Newly identify the label so SwiftUI runs the transition even
        // if the previous banner showed the exact same string.
        content.tick &+= 1

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        // Cancel any in-flight hide, restart the timer.
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdDuration + Self.transitionDuration))
            guard !Task.isCancelled, let self else { return }
            // The transition's out-animation has run by now (SwiftUI
            // owns it). Order the panel out so it isn't holding screen
            // space for nothing.
            self.panel?.orderOut(nil)
        }
    }

    func stop() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Panel construction

    private func buildPanelIfNeeded() {
        guard panel == nil, let frame = panelFrame(width: Self.minWidth) else { return }

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.level = .statusBar
        p.animationBehavior = .none

        let host = NSHostingView(rootView: CopyBannerView(content: content))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host

        self.panel = p
    }

    private func panelFrame(width: CGFloat) -> NSRect? {
        guard let placement = NotchGeometry.placement(), placement.hasNotch else { return nil }
        let notch = placement.collapsedSize
        let screen = placement.screen.frame
        // Center horizontally on the notch midpoint; sit just below the
        // notch with a small visual gap.
        let x = screen.midX - width / 2
        let y = screen.maxY - notch.height - Self.gapBelowNotch - Self.bannerHeight
        return NSRect(x: x, y: y, width: width, height: Self.bannerHeight)
    }

    private static func measureWidth(for label: String) -> CGFloat {
        // Approximate the rendered width: NSAttributedString with the
        // same font we use in the view, plus chrome (icon + paddings).
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (label as NSString).size(withAttributes: attrs).width
        let horizontalPadding: CGFloat = 14 + 14   // matches .padding(.horizontal, 14)
        let raw = textWidth + horizontalPadding
        return min(maxWidth, max(minWidth, raw.rounded(.up)))
    }
}

/// Tiny observable wrapper so the controller can mutate the label and
/// re-trigger the SwiftUI transition without rebuilding the hosting view.
@MainActor
final class BannerContent: ObservableObject {
    @Published var label: String = ""
    /// Monotonic counter so identical consecutive labels still animate
    /// the transition (View identity flips when this increments).
    @Published var tick: UInt = 0
}

private struct CopyBannerView: View {
    @ObservedObject var content: BannerContent
    @State private var visible: Bool = false

    var body: some View {
        ZStack {
            // Pill background — black, rounded, matches the idle pill's
            // tonal feel so the two read as a family even though they
            // live in different panels.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            Text(content.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Slide-in from above + fade. State-driven so the same view
        // reused across show()s animates each time. The `tick` change
        // forces the body to re-evaluate.
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : -10)
        .onChange(of: content.tick) { _, _ in
            // Reset to hidden, then animate to visible, schedule the
            // out-animation to land before the controller orders the
            // panel out.
            visible = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                visible = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeIn(duration: 0.22)) { visible = false }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                visible = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeIn(duration: 0.22)) { visible = false }
            }
        }
    }
}
