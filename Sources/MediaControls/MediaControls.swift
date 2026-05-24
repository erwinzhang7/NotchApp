import Foundation

/// Module façade for media controls. Same shape as ClipboardManager / FileShelf:
/// a Services holder reachable via `MediaControls.shared`. The adapter starts
/// streaming on first access and runs for the lifetime of the app process.
///
/// Why a Perl bridge: on macOS 15.4+ Apple entitlement-locked the private
/// MediaRemote framework to `com.apple.*` processes. `/usr/bin/perl` qualifies
/// (its bundle id is `com.apple.perl5`), so we run the script as a subprocess
/// and parse JSON-line updates from its stdout. See
/// `Vendor/MediaRemoteAdapter/README.md` for license/attribution.
enum MediaControls {
    @MainActor static let shared: Services = Services()

    @MainActor
    final class Services {
        let state: NowPlayingState
        let adapter: MediaRemoteAdapter

        init() {
            let state = NowPlayingState()
            self.state = state
            self.adapter = MediaRemoteAdapter(state: state)
            adapter.start()
        }
    }
}
