import Combine
import Foundation
import IOBluetooth

/// Detects classic-Bluetooth connect/disconnect events for paired
/// devices and emits an activity-worthy event. Way smaller than
/// DynamicNotch's BluetoothService split (which polls every paired
/// device's battery via IORegistry): we only care about "thing just
/// connected, what is it, what's the rough type."
@MainActor
final class BluetoothActivitySource: ObservableObject {
    /// Most recent connected device. Republished so the activity view
    /// can render it even if the engine swap happens after the event.
    @Published private(set) var lastConnected: ConnectedDevice?

    let events = PassthroughSubject<Event, Never>()

    enum Event: Equatable {
        case connected(ConnectedDevice)
    }

    struct ConnectedDevice: Equatable {
        let name: String
        let type: BluetoothDeviceKind
    }

    private var connectionObserver: IOBluetoothUserNotification?
    /// Per-device disconnect observers, keyed by MAC address. Keyed
    /// (rather than a flat array) so reconnects don't accumulate
    /// duplicate observers — a flapping AirPods link was previously
    /// adding a new entry on every reconnect, slowly leaking.
    private var disconnectObserversByAddress: [String: IOBluetoothUserNotification] = [:]

    func start() {
        guard connectionObserver == nil else { return }

        // Global connect notification: fires whenever any paired device
        // completes a baseband connection. The selector is invoked on
        // the main thread by IOBluetooth.
        connectionObserver = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleConnection(_:device:))
        )

        // Seed `lastConnected` with whatever's already connected so the
        // activity view has data on first display.
        if let alreadyConnected = currentlyConnectedDevice() {
            lastConnected = alreadyConnected
        }
    }

    func stop() {
        connectionObserver?.unregister()
        connectionObserver = nil
        disconnectObserversByAddress.values.forEach { $0.unregister() }
        disconnectObserversByAddress.removeAll()
    }

    /// IOBluetooth selector — old-school Objective-C bridging. The
    /// notification fires for every connection. We filter to
    /// audio-class devices with a real name so the noise from random
    /// background pairings (mice, keyboards, watches, system services)
    /// doesn't keep popping the activity. Audio devices get an activity
    /// + a one-shot disconnect watcher so `lastConnected` clears when
    /// they drop.
    @objc private func handleConnection(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let kind = BluetoothDeviceKind.from(classOfDevice: device.classOfDevice)
        let rawName = device.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasUsableName = !rawName.isEmpty

        // Skip notifications for:
        // - non-audio devices (mice, keyboards, watches, etc.)
        // - devices with no resolvable name (system probe-pairings)
        // Both groups produced confusing pop-ups in testing and
        // overwhelmed the activity area on this Mac.
        guard kind != .generic, hasUsableName else {
            return
        }

        let resolved = ConnectedDevice(name: rawName, type: kind)

        lastConnected = resolved
        events.send(.connected(resolved))

        // Dedup disconnect observers by device address — a previously
        // observed device that re-connects should reuse its existing
        // observer rather than stacking another one. Without this, a
        // flapping bluetooth link would leak an observer per cycle.
        let address = device.addressString ?? ""
        guard disconnectObserversByAddress[address] == nil else { return }
        if let disconnectObserver = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleDisconnect(_:device:))
        ) {
            disconnectObserversByAddress[address] = disconnectObserver
        }
    }

    @objc private func handleDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        let address = device.addressString ?? ""
        disconnectObserversByAddress.removeValue(forKey: address)

        // Only clear if the disconnecting device is the one we last
        // surfaced — otherwise leave the last-connected state alone.
        if let last = lastConnected, last.name == (device.name ?? device.addressString ?? "") {
            lastConnected = nil
        }
    }

    /// Snapshot of the first currently-connected paired device. Used on
    /// `start()` to seed state; the engine doesn't emit an event for it
    /// (no transition happened).
    private func currentlyConnectedDevice() -> ConnectedDevice? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        guard let device = paired.first(where: { $0.isConnected() }) else { return nil }
        return ConnectedDevice(
            name: device.name ?? device.addressString ?? "Bluetooth Device",
            type: BluetoothDeviceKind.from(classOfDevice: device.classOfDevice)
        )
    }
}

/// Coarse device taxonomy for picking an SF Symbol. Way leaner than
/// DynamicNotch's `BluetoothAudioDeviceType` (which carries 12 cases
/// distinguishing AirPods generations) because IOBluetooth's
/// classOfDevice bits can't tell those apart anyway.
enum BluetoothDeviceKind: Equatable {
    case airpods
    case headphones
    case speaker
    case generic

    var sfSymbol: String {
        switch self {
        case .airpods:    return "airpods"
        case .headphones: return "headphones"
        case .speaker:    return "hifispeaker.fill"
        // No real "bluetooth" SF Symbol exists; the radio-waves glyph
        // is the closest stand-in. Was previously `"bluetooth"` which
        // logged "No symbol named 'bluetooth' found in system symbol set"
        // and rendered a blank.
        case .generic:    return "dot.radiowaves.left.and.right"
        }
    }

    /// Bluetooth's `classOfDevice` is a 24-bit packed value where the
    /// low 13 bits encode the Major + Minor device class. We look at the
    /// Major Audio bit and the Minor sub-classes to pick a symbol.
    /// Reference: Bluetooth Assigned Numbers — Baseband (Class of Device).
    static func from(classOfDevice: BluetoothClassOfDevice) -> BluetoothDeviceKind {
        let raw = UInt32(classOfDevice)
        // Major Device Class is bits 8..12.
        let majorClass = (raw >> 8) & 0x1F
        // Minor Device Class is bits 2..7.
        let minorClass = (raw >> 2) & 0x3F

        // Major class 0x04 = Audio/Video.
        guard majorClass == 0x04 else { return .generic }

        // Minor sub-classes worth distinguishing for the icon. The
        // Bluetooth spec doesn't carry "is AirPods" — Apple identifies
        // AirPods via the BLE manufacturer-specific advertisement, which
        // IOBluetooth doesn't surface. So everything earbuds-shaped maps
        // to .airpods on the assumption that's what the user has.
        switch minorClass {
        case 0x01, 0x02:        return .headphones    // Wearable headset / hands-free
        case 0x04, 0x06, 0x0A:  return .headphones    // Headphones, Headset, Loudspeaker headset
        case 0x05:              return .speaker       // Loudspeaker
        case 0x0B, 0x0C:        return .airpods       // Earbuds / Earphones (closest BT-class match)
        default:                return .generic
        }
    }
}
