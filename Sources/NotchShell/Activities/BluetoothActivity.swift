import SwiftUI

/// Temporary notification shown when a classic-Bluetooth device just
/// connected. Inspired by DynamicNotch's `BluetoothConnectedNotchContent`
/// but with no settings: hardcoded compact layout, no battery readout
/// (would require IORegistry polling we don't ship yet).

/// Symmetric wing width — same on both sides so the camera dead-zone in
/// the middle stays centered on the physical notch. Sized for the
/// longer leading label this family uses ("AirPods Pro (2nd generation)"
/// truncates to the wing width).
private let bluetoothWingWidth: CGFloat = 170

struct BluetoothConnectedActivity: NotchActivity {
    let id: String = "activity.bluetooth.connected"
    var priority: Int { NotchActivityPriority.bluetooth }

    let device: BluetoothActivitySource.ConnectedDevice

    func size(base: CGSize) -> CGSize {
        CGSize(
            width: base.width + bluetoothWingWidth * 2,
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
            wingWidth: bluetoothWingWidth,
            leadingSymbol: device.type.sfSymbol,
            leadingTint: .white,
            title: device.name,
            trailing: "Connected"
        )
    }
}
