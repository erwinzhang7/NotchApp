import AppKit
import Combine
import Foundation

/// Per-display fullscreen-space detector. Publishes the set of display
/// UUIDs whose current space is a macOS "fullscreen" space (one app
/// owning the whole screen via the green-button flow), refreshed on
/// every `activeSpaceDidChange` notification.
///
/// Why bother: when YouTube / Netflix / Quick Time goes fullscreen on the
/// notched display, our idle pill draws *above* the video. Watching it
/// hide elsewhere on the screen but our pill stays on top is the #1
/// complaint about apps in this category. This detector lets the idle
/// pill (and anyone else who cares) opt out per-display.
///
/// Implementation: private `SkyLight` symbols
/// `SLSManagedDisplayGetCurrentSpace` + `SLSSpaceGetType`. Same family of
/// APIs `SkyLightSpace` already uses; fails closed (empty set) if any
/// symbol disappears on a future macOS.
@MainActor
final class FullscreenSpaceObserver: ObservableObject {
    /// Set of `NSScreen.displayUUID` whose current space is fullscreen.
    @Published private(set) var fullscreenDisplays: Set<String> = []

    private let handle: UnsafeMutableRawPointer?
    private let connection: Int32
    private let isAvailable: Bool

    private typealias SLSMainConnectionIDProc = @convention(c) () -> Int32
    private typealias SLSManagedDisplayGetCurrentSpaceProc = @convention(c) (Int32, CFString) -> UInt64
    private typealias SLSSpaceGetTypeProc = @convention(c) (Int32, UInt64) -> Int32

    private let _getCurrentSpace: SLSManagedDisplayGetCurrentSpaceProc?
    private let _spaceType: SLSSpaceGetTypeProc?

    /// macOS reports space type 4 for "fullscreen" (one app owning the
    /// whole display via the green-button flow). Type 0 is a normal
    /// user-managed space, type 2 is system (e.g. dashboard) — we don't
    /// hide for either.
    private static let fullscreenSpaceType: Int32 = 4

    private var observer: NSObjectProtocol?

    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        let h = dlopen(path, RTLD_NOW)
        self.handle = h

        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        if let mainConn = sym("SLSMainConnectionID", as: SLSMainConnectionIDProc.self),
           let curSpace = sym("SLSManagedDisplayGetCurrentSpace", as: SLSManagedDisplayGetCurrentSpaceProc.self),
           let spType = sym("SLSSpaceGetType", as: SLSSpaceGetTypeProc.self) {
            self.connection = mainConn()
            self._getCurrentSpace = curSpace
            self._spaceType = spType
            self.isAvailable = true
        } else {
            self.connection = 0
            self._getCurrentSpace = nil
            self._spaceType = nil
            self.isAvailable = false
        }
    }

    func start() {
        guard isAvailable, observer == nil else { return }
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        // The notification center holds the observer strongly; it must be
        // removed before this object dies. `stop()` is the supported path,
        // but defend against missed cleanup.
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh() {
        guard let getSpace = _getCurrentSpace, let spaceType = _spaceType else { return }
        var next: Set<String> = []
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID else { continue }
            let spaceID = getSpace(connection, uuid as CFString)
            if spaceID != 0, spaceType(connection, spaceID) == Self.fullscreenSpaceType {
                next.insert(uuid)
            }
        }
        if next != fullscreenDisplays {
            fullscreenDisplays = next
        }
    }
}
