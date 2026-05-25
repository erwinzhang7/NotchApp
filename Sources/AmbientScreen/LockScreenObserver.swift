import Foundation

/// Bridges the well-known DistributedNotificationCenter names for screen
/// lock and screensaver lifecycle. Used to *suppress* the ambient window
/// while macOS owns the display (system lockscreen / screensaver sit
/// above app windows), then restore it after unlock.
@MainActor
final class LockScreenObserver {
    var onLocked: (() -> Void)?
    var onUnlocked: (() -> Void)?
    var onScreensaverStart: (() -> Void)?
    var onScreensaverStop: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []

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

        add("com.apple.screenIsLocked")           { [weak self] in self?.onLocked?() }
        add("com.apple.screenIsUnlocked")         { [weak self] in self?.onUnlocked?() }
        add("com.apple.screensaver.didstart")     { [weak self] in self?.onScreensaverStart?() }
        add("com.apple.screensaver.didstop")      { [weak self] in self?.onScreensaverStop?() }
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        for token in tokens { dnc.removeObserver(token) }
        tokens.removeAll()
    }

    deinit {
        let dnc = DistributedNotificationCenter.default()
        for token in tokens { dnc.removeObserver(token) }
    }
}
