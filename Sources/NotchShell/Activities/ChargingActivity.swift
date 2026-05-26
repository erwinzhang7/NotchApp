import SwiftUI

/// Temporary notification shown when AC power is connected. Mirrors the
/// shape of DynamicNotch's `ChargerNotchContent` but with a hardcoded
/// look — no settings hooks, no localization, no stroke colors.

/// Asymmetric wing widths for power ribbons: leading carries a short
/// label ("Charging" / "Low Battery" / "Charged") + a 12pt symbol;
/// trailing carries just a 3- or 4-char percentage. Sized so "Low Battery"
/// (~74pt at 12pt semibold) clears the camera with ~16pt of padding +
/// curve clearance, and "100%" sits comfortably in the trailing wing.
private let powerLeadingWingWidth: CGFloat = 130
private let powerTrailingWingWidth: CGFloat = 70

struct ChargingActivity: NotchActivity {
    let id: String = "activity.power.charging"
    var priority: Int { NotchActivityPriority.power }

    let batteryLevel: Int
    let isCharging: Bool

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + powerLeadingWingWidth + powerTrailingWingWidth,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(ChargingActivityView(batteryLevel: batteryLevel, isCharging: isCharging))
    }
}

/// "Low battery, plug in" / "Charged" temporary notifications. Same
/// visual frame as the charger activity, different icon + label so the
/// engine can swap freely.
struct LowPowerActivity: NotchActivity {
    let id: String = "activity.power.low"
    var priority: Int { NotchActivityPriority.power }

    let batteryLevel: Int

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + powerLeadingWingWidth + powerTrailingWingWidth,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(LowPowerActivityView(batteryLevel: batteryLevel))
    }
}

struct FullPowerActivity: NotchActivity {
    let id: String = "activity.power.full"
    var priority: Int { NotchActivityPriority.power }

    let batteryLevel: Int

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + powerLeadingWingWidth + powerTrailingWingWidth,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(FullPowerActivityView(batteryLevel: batteryLevel))
    }
}

// MARK: - Views

private struct ChargingActivityView: View {
    let batteryLevel: Int
    let isCharging: Bool

    var body: some View {
        ActivityRibbon(
            leadingWingWidth: powerLeadingWingWidth,
            trailingWingWidth: powerTrailingWingWidth,
            leadingSymbol: "bolt.fill",
            leadingTint: .green,
            title: isCharging ? "Charging" : "Plugged In",
            trailing: "\(batteryLevel)%"
        )
    }
}

private struct LowPowerActivityView: View {
    let batteryLevel: Int

    var body: some View {
        ActivityRibbon(
            leadingWingWidth: powerLeadingWingWidth,
            trailingWingWidth: powerTrailingWingWidth,
            leadingSymbol: "battery.25percent",
            leadingTint: .yellow,
            title: "Low Battery",
            trailing: "\(batteryLevel)%"
        )
    }
}

private struct FullPowerActivityView: View {
    let batteryLevel: Int

    var body: some View {
        ActivityRibbon(
            leadingWingWidth: powerLeadingWingWidth,
            trailingWingWidth: powerTrailingWingWidth,
            leadingSymbol: "battery.100percent",
            leadingTint: .green,
            title: "Charged",
            trailing: "\(batteryLevel)%"
        )
    }
}

/// Shared compact-activity layout. Three-column structure with
/// explicit wing widths so leading and trailing don't fight over the
/// leftover space (was causing long labels to spill into the camera
/// dead-zone). Each activity sizes its own wings to fit its content.
struct ActivityRibbon: View {
    @Environment(\.physicalNotchWidth) private var physicalNotchWidth

    let leadingWingWidth: CGFloat
    let trailingWingWidth: CGFloat
    let leadingSymbol: String
    let leadingTint: Color
    let title: String
    let trailing: String

    /// Padding kept clear on the camera-side of each wing. 8pt gives
    /// the text breathing room from the lens AND clears the inward top
    /// curve (`baseHeight/3 - 4 ≈ 6.7pt`).
    private let cameraSidePadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            // Leading wing — right-aligned so the symbol + title sit
            // snug against the camera cutout. Fixed width per activity
            // so content can't reflow into the dead-zone.
            HStack(spacing: 5) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(leadingTint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.trailing, cameraSidePadding)
            .frame(width: leadingWingWidth, alignment: .trailing)

            // Camera dead-zone — exact notch width, transparent so the
            // black pill behind shows through (and the camera lens
            // remains unobscured).
            Color.clear
                .frame(width: physicalNotchWidth)

            // Trailing wing — left-aligned for the same reason.
            Text(trailing)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, cameraSidePadding)
                .frame(width: trailingWingWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}
