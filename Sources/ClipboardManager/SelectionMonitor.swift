import AppKit
import ApplicationServices
import Combine
import Foundation

/// Watches text selections across the system via the Accessibility API
/// and emits a `Captured(text:)` event when a selection of ≥ 2 characters
/// has visibly settled (same string seen on two consecutive ticks).
///
/// **Why polling, not AX notifications**: `kAXSelectedTextChangedNotification`
/// has to be observed PER focused UI element, and the right element is
/// often a deeply-nested AXTextArea inside an AXScrollArea inside an
/// AXWindow. Re-binding the observer on every focus change is brittle —
/// `kAXFocusedUIElementChangedNotification` doesn't fire reliably across
/// every app, especially Electron / web views, so observations get
/// stale silently. A 250ms poll on the system-wide focused element is
/// cheap (sub-millisecond per tick) and works uniformly across native
/// apps, Catalyst, Electron, and browser content.
///
/// Settle detection: emit only when the trimmed selection text is the
/// same on two consecutive ticks (≥ 250ms apart). That naturally
/// debounces mid-drag intermediate selections without spamming.
///
/// Skip list: never reads selected text from loginwindow / Keychain /
/// SecurityAgent. Belt-and-suspenders with secure-input mode.
@MainActor
final class SelectionMonitor {
    struct Captured: Equatable {
        let text: String
    }

    let events = PassthroughSubject<Captured, Never>()

    private let pollInterval: TimeInterval = 0.25
    private let minimumCharacters: Int = 2

    private static let blockedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
    ]

    private var systemElement: AXUIElement?
    private var pollTimer: Timer?
    private var trustPollTimer: Timer?
    private var promptedForAccess = false
    private var isRunning = false

    /// Last non-empty trimmed text we observed at a poll. When two
    /// consecutive ticks see the same text, we publish once and clear
    /// `lastPublishedText` is updated so we don't re-publish until the
    /// selection actually changes again.
    private var lastSeenText: String?
    private var lastPublishedText: String?

    func start() {
        guard !isRunning else { return }
        let trusted = AXIsProcessTrusted()
        NSLog("[SelectionMonitor] start() — AX trusted=%@", trusted ? "Y" : "N")
        if trusted {
            installPollTimer()
            isRunning = true
            return
        }
        NSLog("[SelectionMonitor] not trusted — prompting once + polling for trust")
        if !promptedForAccess { promptForAccessibility() }
        startTrustPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        systemElement = nil
        lastSeenText = nil
        lastPublishedText = nil
        isRunning = false
    }

    // MARK: - Poll

    private func installPollTimer() {
        systemElement = AXUIElementCreateSystemWide()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        NSLog("[SelectionMonitor] poll timer installed (interval=%.2fs)", pollInterval)
    }

    private func tick() {
        guard let system = systemElement else { return }

        // Resolve the focused element from the system-wide root every
        // tick. Cheap; AX caches enough of this internally that we
        // don't measure the call on a profiler.
        var focusedValue: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusResult == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            // No focus → clear seen-state so a stale selection doesn't
            // re-fire when focus returns.
            lastSeenText = nil
            return
        }
        let element = focused as! AXUIElement

        if isBlocked(element: element) {
            lastSeenText = nil
            return
        }

        var selectionValue: AnyObject?
        let selectionResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectionValue
        )
        guard selectionResult == .success, let raw = selectionValue as? String else {
            lastSeenText = nil
            return
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else {
            lastSeenText = nil
            return
        }

        // Settle: only emit once the same text appears on two
        // consecutive ticks, AND we haven't already published it.
        if trimmed == lastSeenText, trimmed != lastPublishedText {
            lastPublishedText = trimmed
            events.send(Captured(text: trimmed))
        }
        lastSeenText = trimmed
    }

    private func isBlocked(element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        guard let bundleID = app.bundleIdentifier else { return false }
        return Self.blockedBundleIDs.contains(bundleID)
    }

    // MARK: - Trust handling

    private func promptForAccessibility() {
        promptedForAccess = true
        NSLog("[SelectionMonitor] showing Accessibility prompt + system permission dialog")

        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "NotchApp needs Accessibility access"
        alert.informativeText = """
            To auto-copy highlighted text into the clipboard, enable \
            NotchApp in System Settings → Privacy & Security → \
            Accessibility.

            Without this, the toggle stays on but the feature is a \
            no-op — you can still copy manually with Cmd+C.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func startTrustPolling() {
        guard trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() {
                    NSLog("[SelectionMonitor] trust acquired via poll — installing observers")
                    self.installPollTimer()
                    self.isRunning = true
                    self.trustPollTimer?.invalidate()
                    self.trustPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }
}
