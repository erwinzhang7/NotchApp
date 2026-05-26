import SwiftUI

/// Notch-shaped widget mirroring Atoll's layout: the hardware notch sits
/// in the center as solid black, with indicator zones extending to its
/// left and right. Lock icon lives in the left indicator zone (where the
/// hardware notch isn't drawing). Total width = notchWidth + 2 * indicator
/// + 2 * padding; height = notchHeight.
struct LockNotchIndicatorView: View {
    @ObservedObject var lockObserver: LockScreenObserver
    let notchSize: CGSize

    /// Side-indicator dimensions match Atoll's `notchSize.height - 12`.
    private var indicatorSize: CGFloat { max(0, notchSize.height - 12) }

    var body: some View {
        HStack(spacing: 0) {
            // Left indicator zone — lock icon.
            Color.clear
                .overlay {
                    Image(systemName: lockObserver.isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: max(8, indicatorSize * 0.55), weight: .semibold))
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
        .frame(width: notchSize.width + indicatorSize * 2, height: notchSize.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: notchSize.height / 2, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: lockObserver.isLocked)
    }
}
