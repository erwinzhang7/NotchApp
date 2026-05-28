import AppKit

/// Thin wrapper around `NSSharingService(.sendViaAirDrop)`. Pattern lifted
/// from mew-notch: the sharing service handles the panel UI itself; we just
/// hand it the files and let macOS take over.
enum AirDropService {
    @discardableResult
    static func send(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return false }
        service.perform(withItems: urls)
        return true
    }
}
