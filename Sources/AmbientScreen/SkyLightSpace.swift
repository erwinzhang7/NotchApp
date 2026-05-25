import AppKit
import Foundation

/// Private-API bridge into `SkyLight.framework` for the one specific
/// trick we want: create a window-server "Space" at the absolute level
/// macOS reserves for Notification Center on the lock screen (400 —
/// above the lock layer at 300), then move our NSWindow into it. The
/// window then renders on top of the lock screen.
///
/// Technique referenced from Lakr233/SkyLightWindow (MIT) — see
/// https://github.com/Lakr233/SkyLightWindow for the original. The
/// function signatures and the absolute-level constants are public
/// macOS internals reverse-engineered by the community over years.
///
/// **Caveats**:
/// - Private framework. Apple can change/remove these symbols on any
///   macOS update; we'd fail to dlsym and `isAvailable` would go false.
/// - Not allowed on the Mac App Store for sandboxed apps; NotchApp ships
///   outside the App Store so this isn't a blocker for distribution.
@MainActor
final class SkyLightSpace {
    /// Absolute z-order ranks used by the window server when ordering
    /// spaces. The constants are exposed by the private SkyLight API; we
    /// only need the one between ScreenLock (300) and BootProgress (500).
    enum AbsoluteLevel: Int32 {
        case `default` = 0
        case setupAssistant = 100
        case securityAgent = 200
        case screenLock = 300
        case notificationCenterAtScreenLock = 400
        case bootProgress = 500
        case voiceOver = 600
    }

    static let shared = SkyLightSpace()

    /// True if all required private symbols were dlsym'd and the initial
    /// space was created successfully. False on the first macOS that
    /// renames or removes any of them.
    let isAvailable: Bool

    private let handle: UnsafeMutableRawPointer?
    private let connection: Int32
    private let space: Int32

    // C function shims dlsym'd from /System/Library/PrivateFrameworks/SkyLight.framework
    private typealias SLSMainConnectionIDProc = @convention(c) () -> Int32
    private typealias SLSSpaceCreateProc = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLSSpaceSetAbsoluteLevelProc = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLSShowSpacesProc = @convention(c) (Int32, CFArray) -> Int32
    private typealias SLSSpaceAddWindowsAndRemoveFromSpacesProc = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let _spaceAddWindows: SLSSpaceAddWindowsAndRemoveFromSpacesProc?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        let h = dlopen(path, RTLD_NOW)
        self.handle = h

        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        guard
            let mainConn = sym("SLSMainConnectionID", as: SLSMainConnectionIDProc.self),
            let spaceCreate = sym("SLSSpaceCreate", as: SLSSpaceCreateProc.self),
            let setLevel = sym("SLSSpaceSetAbsoluteLevel", as: SLSSpaceSetAbsoluteLevelProc.self),
            let showSpaces = sym("SLSShowSpaces", as: SLSShowSpacesProc.self),
            let addWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SLSSpaceAddWindowsAndRemoveFromSpacesProc.self)
        else {
            self.connection = 0
            self.space = 0
            self._spaceAddWindows = nil
            self.isAvailable = false
            return
        }

        let conn = mainConn()
        let sp = spaceCreate(conn, 1, 0)
        _ = setLevel(conn, sp, AbsoluteLevel.notificationCenterAtScreenLock.rawValue)
        _ = showSpaces(conn, [sp] as CFArray)

        self.connection = conn
        self.space = sp
        self._spaceAddWindows = addWindows
        self.isAvailable = sp != 0
    }

    /// Move an NSWindow into our above-lock-screen Space. Subsequent calls
    /// re-assign the same window safely. Window-side prep (the caller
    /// should set before calling): `canBecomeVisibleWithoutLogin = true`,
    /// `collectionBehavior` includes `.canJoinAllSpaces` and `.stationary`,
    /// borderless / non-activating.
    func assign(_ window: NSWindow) {
        guard isAvailable, let add = _spaceAddWindows else { return }
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
