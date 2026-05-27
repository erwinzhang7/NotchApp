import AppKit
import ApplicationServices
import Combine
import Foundation

/// Watches text selections across the system via the Accessibility API
/// and emits a `Captured(text:)` event when a selection of ≥ 2 characters
/// has visibly settled (same string seen on two consecutive ticks).
///
/// **Why polling, not AX notifications**: `kAXSelectedTextChangedNotification`
/// has to be observed PER focused UI element, and `kAXFocusedUIElementChangedNotification`
/// doesn't fire reliably across web views / Electron, so observations
/// go stale silently. A 250ms poll on the system-wide focused element
/// is cheap (sub-millisecond per tick) and resilient.
///
/// **Reading selections in WebKit / Chromium**: a flat `kAXSelectedText`
/// read on the focused element only works for native text hosts
/// (NSTextField, NSTextView — Terminal, TextEdit, Safari's URL bar,
/// etc.). For page content the system reports the WKWebView wrapper as
/// focused, but selection lives inside the AXWebArea below — we have to
/// descend a few levels to find it. Chromium goes further: it doesn't
/// expose any AX tree at all until an assistive client signals interest
/// by setting `AXManualAccessibility` / `AXEnhancedUserInterface` on the
/// app element. We set both on every regular running app at start and
/// on every app activation, which wakes Chrome / Electron's tree.
///
/// Combined: a fast direct read for native fields + bounded recursive
/// descent for browser/electron content, plus the wake call on app
/// activation. Covers Safari page content, Chrome content, VS Code,
/// Slack, etc.
///
/// Settle detection: emit only when the trimmed selection text is the
/// same on two consecutive ticks (≥ 250ms apart). Naturally debounces
/// mid-drag intermediate selections.
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
    private var workspaceObserver: NSObjectProtocol?
    private var promptedForAccess = false
    private var isRunning = false

    /// Max levels deep `selectedText(in:maxDepth:)` walks looking for a
    /// child that exposes `kAXSelectedTextAttribute`. WKWebView wraps an
    /// AXScrollArea wrapping an AXWebArea (~2-3 levels); Chromium nodes
    /// sit at similar depth. 4 covers both with headroom.
    private let maxDescentDepth: Int = 4

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
            wakeAllRunningApps()
            installWorkspaceObserver()
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
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserver = nil
        }
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

        guard let raw = selectedText(in: element, maxDepth: maxDescentDepth) else {
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

    /// Try the focused element directly (fast path for native text
    /// fields), then walk children to a bounded depth. Returns the
    /// first non-empty `kAXSelectedTextAttribute` found.
    private func selectedText(in element: AXUIElement, maxDepth: Int) -> String? {
        if let direct = directSelectedText(element) { return direct }
        guard maxDepth > 0 else { return nil }
        for child in childrenOf(element) {
            if let nested = selectedText(in: child, maxDepth: maxDepth - 1) {
                return nested
            }
        }
        return nil
    }

    private func directSelectedText(_ element: AXUIElement) -> String? {
        // Path 1 — kAXSelectedText. Native NSTextField / NSTextView /
        // editable content covered: Terminal, TextEdit, Mail, URL bar,
        // VS Code's editor (via Electron AX once woken), Chromium's
        // content nodes.
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success, let s = value as? String, !s.isEmpty {
            return s
        }

        // Path 2 — WebKit text markers. Safari (and any WKWebView host)
        // doesn't put page-content selections in kAXSelectedText. The
        // AXWebArea node exposes an opaque AXSelectedTextMarkerRange,
        // which has to be passed back through the parameterized
        // attribute AXStringForTextMarkerRange to materialize as a
        // string. These constants aren't in the public ApplicationServices
        // headers — they're WebKit/VoiceOver internals stable across
        // macOS versions — so we pass them as raw CFString names.
        var markerRange: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success, let range = markerRange else {
            return nil
        }
        var stringValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            range as CFTypeRef,
            &stringValue
        ) == .success, let s = stringValue as? String, !s.isEmpty else {
            return nil
        }
        return s
    }

    private func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        )
        guard result == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }

    // MARK: - Waking reluctant AX trees (Chromium / Electron)

    /// Both attributes signal "an assistive client is here, please build
    /// your AX tree". Apple's `AXEnhancedUserInterface` is the documented
    /// hook; `AXManualAccessibility` is the Chromium-specific name and
    /// what current Chrome / Electron releases actually check for.
    /// Setting both is safe — apps that don't recognize either just
    /// ignore the unknown attribute.
    private func wake(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func wakeAllRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier > 0 else { continue }
            wake(pid: app.processIdentifier)
        }
    }

    private func installWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier > 0 else { return }
                self.wake(pid: app.processIdentifier)
            }
        }
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
                    self.wakeAllRunningApps()
                    self.installWorkspaceObserver()
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
