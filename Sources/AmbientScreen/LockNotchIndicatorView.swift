import SwiftUI

/// Notch-shaped widget mirroring Atoll's layout: the hardware notch sits
/// in the center as solid black, with indicator zones extending to its
/// left and right. Lock icon lives in the left indicator zone (where the
/// hardware notch isn't drawing). Total width = notchWidth + 2 * indicator
/// + 2 * padding; height = notchHeight.
struct LockNotchIndicatorView: View {
    @ObservedObject var lockObserver: LockScreenObserver
    let notchSize: CGSize

    /// Lateral sweep on the notch shape's top corners (must match
    /// what's used in the panel sizing math).
    static let topSweep: CGFloat = 8
    /// Extra horizontal slack on each side of the indicator zones so
    /// the lock icon has room to breathe and the swept corners have
    /// somewhere to extend into without crowding the icon.
    static let horizontalPadding: CGFloat = 10

    /// Indicator side-zone width. Square zones the height of the notch
    /// give the icon a comfortable centered hit area — the Atoll
    /// `notchSize.height - 12` was a little cramped on a 38pt notch.
    static func indicatorSize(for notchSize: CGSize) -> CGFloat {
        max(0, notchSize.height)
    }

    /// Total visible width including indicator zones + padding. Used by
    /// the controller to size the host panel so the math stays in one
    /// place.
    static func totalWidth(for notchSize: CGSize) -> CGFloat {
        notchSize.width + indicatorSize(for: notchSize) * 2 + horizontalPadding * 2
    }

    private var indicatorSize: CGFloat { Self.indicatorSize(for: notchSize) }

    var body: some View {
        HStack(spacing: 0) {
            // Left indicator zone — lock icon.
            Color.clear
                .overlay {
                    Image(systemName: lockObserver.isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: min(16, indicatorSize * 0.5), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: indicatorSize, height: notchSize.height)

            // Center — the hardware notch, solid black so it blends in.
            Rectangle()
                .fill(.black)
                .frame(width: notchSize.width, height: notchSize.height)

            // Right indicator zone — empty placeholder for symmetry.
            Color.clear
                .frame(width: indicatorSize, height: notchSize.height)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: Self.totalWidth(for: notchSize), height: notchSize.height)
        .background(Color.black)
        // Use our app's standard notch outline — swept-out top corners +
        // rounded bottom — same shape as the main notch panel so the
        // lock indicator visually matches the rest of the app.
        .clipShape(NotchPanelShape(topSweep: Self.topSweep, bottomConvexRadius: 10))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: lockObserver.isLocked)
    }
}
