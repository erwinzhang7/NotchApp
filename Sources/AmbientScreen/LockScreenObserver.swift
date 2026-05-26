import AppKit
import Combine
import Foundation

/// Bridges the well-known DistributedNotificationCenter names for screen
/// lock and screensaver lifecycle. Used to *suppress* the ambient window
/// while macOS owns the display (system lockscreen / screensaver sit
/// above app windows), then restore it after unlock.
///
/// Also publishes `isLocked` so SwiftUI views (e.g. the lock-screen
/// widget card's lock badge) can react to lock-state changes directly.
///
/// `isPreparingLock` (ported from DynamicNotch's LockScreenManager) flips
/// true when `NSWorkspace.sessionDidResignActive` fires — typically a
/// few hundred ms before `com.apple.screenIsLocked`. Using it to gate
/// presentation lets the lock-screen widget appear in the same frame the
/// system starts dimming, eliminating the brief empty-flash between
/// "user walked away" and "lock notification arrives".
@MainActor
final class LockScreenObserver: ObservableObject {
    /// Latest known lock state. Driven by the DNC events below; stays
    /// false during screensaver-only (no password sheet) periods.
    @Published private(set) var isLocked: Bool = false

    /// True between session-resign-active and the actual lock event (or
    /// session-become-active, whichever wins). Lets downstream views show
    /// their lock-state UI a beat earlier than the DNC event would allow.
    @Published private(set) var isPreparingLock: Bool = false

    /// Convenience flag covering the full "lock chrome should be on screen"
    /// window — preparing + actually locked. Mirrors DynamicNotch's
    /// `LockScreenManager.isShowingLockPresentation`.
    var isShowingLockPresentation: Bool { isLocked || isPreparingLock }

    var onLocked: (() -> Void)?
    var onUnlocked: (() -> Void)?
    var onScreensaverStart: (() -> Void)?
    var onScreensaverStop: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    func start() {
        stop()
        let dnc = DistributedNotificationCenter.default()
        let queue = OperationQueue.main

        func add(_ name: String, _ handler: @escaping () -> Void) {
            let t = dnc.addObserver(forName: .init(name), object: nil, queue: queue) { _ in
                // OperationQueue.main delivers on main thread but isn't
                // typed as @MainActor; assume isolation explicitly.
                MainActor.assumeIsolated(handler)
            }
            tokens.append(t)
        }

        add("com.apple.screenIsLocked")           { [weak self] in
            self?.isPreparingLock = false
            self?.isLocked = true
            self?.onLocked?()
        }
        add("com.apple.screenIsUnlocked")         { [weak self] in
            self?.isPreparingLock = false
            self?.isLocked = false
            self?.onUnlocked?()
        }
        add("com.apple.screensaver.didstart")     { [weak self] in self?.onScreensaverStart?() }
        add("com.apple.screensaver.didstop")      { [weak self] in self?.onScreensaverStop?() }

        // Pre-lock detection — fires a few hundred ms before screenIsLocked
        // so the widget can be on screen the instant the system begins
        // dimming. If the user immediately returns (no actual lock),
        // sessionDidBecomeActive clears the preparing flag.
        let workspace = NSWorkspace.shared.notificationCenter
        let resignToken = workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: queue
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLocked else { return }
                self.isPreparingLock = true
            }
        }
        let becomeToken = workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: queue
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLocked else { return }
                self.isPreparingLock = false
            }
        }
        workspaceTokens.append(contentsOf: [resignToken, becomeToken])
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        for token in tokens { dnc.removeObserver(token) }
        tokens.removeAll()

        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { workspace.removeObserver(token) }
        workspaceTokens.removeAll()
    }

    deinit {
        let dnc = DistributedNotificationCenter.default()
        for token in tokens { dnc.removeObserver(token) }
        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { workspace.removeObserver(token) }
    }
}
