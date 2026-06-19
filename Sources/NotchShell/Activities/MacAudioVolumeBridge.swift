import Combine
import Foundation

/// Bridges macAudio's volume broadcasts into the notch volume ribbon.
///
/// macAudio owns volume control for multi-output device sets: it syncs a
/// single master level across the member devices because a stacked aggregate
/// exposes no settable master volume of its own. There is therefore no
/// CoreAudio property `VolumeActivitySource` could observe to learn that
/// master level — macAudio has to tell us. It posts a DistributedNotification
/// on every change, which we render as the standard volume activity.
///
/// While macAudio is running, `MediaKeySuppressor` cedes the hardware
/// volume/mute keys to it, so this bridge is the only volume-ribbon source in
/// that mode. When macAudio isn't running, NotchApp drives volume itself via
/// `VolumeActivitySource` and this bridge simply stays silent.
@MainActor
final class MacAudioVolumeBridge {
    struct Snapshot: Equatable {
        let level: Int
        let isMuted: Bool
    }

    let events = PassthroughSubject<Snapshot, Never>()

    /// Must match `SyncedVolumeController.volumeDidChangeNotification` in macAudio.
    static let notificationName = "com.erwinzhang.macAudio.volumeDidChange"

    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.notificationName),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Distributed-notification userInfo arrives as string values.
                let info = note.userInfo as? [String: String]
                guard let levelString = info?["level"], let level = Int(levelString) else { return }
                self.events.send(Snapshot(
                    level: min(max(level, 0), 100),
                    isMuted: info?["muted"] == "1"
                ))
            }
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
