import SwiftUI

/// Temporary notification shown when AC power is connected. Mirrors the
/// shape of DynamicNotch's `ChargerNotchContent` but with a hardcoded
/// look — no settings hooks, no localization, no stroke colors.

/// Asymmetric wing widths for power ribbons: leading carries a short
/// label ("Charging" / "Low Battery" / "Charged") + a 12pt symbol;
/// trailing carries just a 3- or 4-char percentage. Sized so "Low Battery"
/// (~74pt at 12pt semibold) clears the camera with ~16pt of padding +
/// curve clearance, and "100%" sits comfortably in the trailing wing.
/// Symmetric wing width (applied to both sides so the dead-zone stays
/// centered on the notch). Sized for the longest leading label this
/// family uses ("Plugged In" / "Low Battery" / "Charged" + icon).
private let powerWingWidth: CGFloat = 130

struct ChargingActivity: NotchActivity {
    let id: String = "activity.power.charging"
    var priority: Int { NotchActivityPriority.power }

    let batteryLevel: Int
    let isCharging: Bool

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + powerWingWidth * 2,
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
            width: base.width + powerWingWidth * 2,
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
            width: base.width + powerWingWidth * 2,
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
            wingWidth: powerWingWidth,
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
            wingWidth: powerWingWidth,
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
            wingWidth: powerWingWidth,
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
///
/// Content alignment: leading wing is **left-aligned** (icon + title
/// hug the outer left edge of the pill) and trailing wing is
/// **right-aligned** (value hugs the outer right edge). Per user
/// preference — was previously snug against the camera, which left a
/// gap between the box edge and the text and gave a "floating in the
/// middle" feel.
struct ActivityRibbon: View {
    @Environment(\.physicalNotchWidth) private var physicalNotchWidth

    /// **Symmetric** wing width — applied identically to both sides so the
    /// camera dead-zone in the middle stays exactly centered on the
    /// physical notch. Passing different leading/trailing widths used
    /// to shift the dead-zone off the camera by `(leading-trailing)/2`,
    /// which made long leading-wing content (e.g. "Brightness") visibly
    /// poke into the camera area. Activities pick this as the *larger*
    /// of the two sides they actually need.
    let wingWidth: CGFloat
    let leadingSymbol: String
    let leadingTint: Color
    let title: String
    let trailing: String

    /// Padding kept clear on the outer (box-edge) side of each wing.
    /// 10pt sits a little inside the inward top curve so the icon
    /// doesn't get clipped on the rounded corner.
    private let edgePadding: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            // Leading wing — left-aligned, icon + title flush against
            // the left edge of the pill (with edgePadding so they
            // clear the inward top-corner curve).
            //
            // The Text gets `.frame(maxWidth: .infinity, alignment: .leading)`
            // + `.layoutPriority(0)` and the Image gets `.layoutPriority(1)`.
            // Without that, SwiftUI gives Text its full natural width
            // (ignoring the outer 170pt wing frame, which only
            // *positions* content, not constrains it), so long names
            // like "Erwin's AirPods Pro (2nd generation)" spilled
            // right past the wing into the camera dead-zone instead
            // of truncating. The explicit maxWidth = .infinity tells
            // Text to accept the remaining space; truncationMode(.tail)
            // then actually kicks in.
            // `.clipped()` on the wing is a belt-and-suspenders
            // visual fence so any pathological overflow still can't
            // leak past the wing rect into the notch area.
            HStack(spacing: 5) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(leadingTint)
                    .layoutPriority(1)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
            }
            .padding(.leading, edgePadding)
            .frame(width: wingWidth, alignment: .leading)
            .clipped()

            // Camera dead-zone — exact notch width, transparent so the
            // black pill behind shows through (and the camera lens
            // remains unobscured).
            Color.clear
                .frame(width: physicalNotchWidth)

            // Trailing wing — right-aligned, value flush against the
            // right edge of the pill.
            Text(trailing)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.trailing, edgePadding)
                .frame(width: wingWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }
}
