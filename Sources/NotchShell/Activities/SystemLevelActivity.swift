import SwiftUI

/// Symmetric wing width — same on both sides so the camera dead-zone
/// in the middle stays centered on the physical notch. Sized for the
/// longer leading label this family uses ("Brightness" + icon).
private let systemLevelWingWidth: CGFloat = 112

struct BrightnessActivity: NotchActivity {
    let id: String = "activity.brightness"
    var priority: Int { NotchActivityPriority.systemLevel }

    let level: Int

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + systemLevelWingWidth * 2,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(
            ActivityRibbon(
                wingWidth: systemLevelWingWidth,
                leadingSymbol: "sun.max.fill",
                leadingTint: .yellow,
                title: "Brightness",
                trailing: "\(level)%"
            )
        )
    }
}

struct VolumeActivity: NotchActivity {
    let id: String = "activity.volume"
    var priority: Int { NotchActivityPriority.systemLevel }

    let level: Int
    let isMuted: Bool

    private var symbol: String {
        if isMuted || level == 0 { return "speaker.slash.fill" }
        if level < 34 { return "speaker.wave.1.fill" }
        if level < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + systemLevelWingWidth * 2,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(
            ActivityRibbon(
                wingWidth: systemLevelWingWidth,
                leadingSymbol: symbol,
                leadingTint: .white,
                title: isMuted ? "Muted" : "Volume",
                trailing: "\(level)%"
            )
        )
    }
}
