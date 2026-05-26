import SwiftUI

/// Temporary notification shown when a classic-Bluetooth device just
/// connected. Inspired by DynamicNotch's `BluetoothConnectedNotchContent`
/// but with no settings: hardcoded compact layout, no battery readout
/// (would require IORegistry polling we don't ship yet).

/// Asymmetric wings: leading carries the device name (highly variable
/// length — "AirPods Pro (2nd generation)" is 160pt+ at 12pt medium),
/// trailing carries the static "Connected" label.
private let bluetoothLeadingWingWidth: CGFloat = 170
private let bluetoothTrailingWingWidth: CGFloat = 90

struct BluetoothConnectedActivity: NotchActivity {
    let id: String = "activity.bluetooth.connected"
    var priority: Int { NotchActivityPriority.bluetooth }

    let device: BluetoothActivitySource.ConnectedDevice

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + bluetoothLeadingWingWidth + bluetoothTrailingWingWidth,
            height: base.height
        )
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(BluetoothConnectedActivityView(device: device))
    }
}

private struct BluetoothConnectedActivityView: View {
    let device: BluetoothActivitySource.ConnectedDevice

    var body: some View {
        ActivityRibbon(
            leadingWingWidth: bluetoothLeadingWingWidth,
            trailingWingWidth: bluetoothTrailingWingWidth,
            leadingSymbol: device.type.sfSymbol,
            leadingTint: .white,
            title: device.name,
            trailing: "Connected"
        )
    }
}
