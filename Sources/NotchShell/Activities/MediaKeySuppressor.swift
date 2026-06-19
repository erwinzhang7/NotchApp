import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Intercepts hardware brightness / volume / mute keys before macOS sees
/// them and drives the equivalent change ourselves. Result: the system
/// OSDUIHelper never fires, so the user only sees our notch activity
/// ribbon — no double HUD.
///
/// Requires Accessibility permission (System Settings → Privacy & Security
/// → Accessibility). Without it, `CGEvent.tapCreate` returns nil and
/// suppression is silently a no-op — the system continues to handle the
/// keys natively. We surface a one-time NSAlert pointing the user there
/// and then poll for trust every couple seconds so granting it mid-session
/// activates suppression without a relaunch.
///
/// Step sizes mirror the macOS default exactly:
/// - Plain key: 1/16 (0.0625)
/// - Shift + Option held: 1/64 (0.015625), the fine-grain quarter step
@MainActor
final class MediaKeySuppressor {
    private let brightness: BrightnessActivitySource
    private let volume: VolumeActivitySource

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustPollTimer: Timer?
    private var promptedForAccess = false
    private var workspaceObservers: [NSObjectProtocol] = []

    nonisolated private static let normalStep: Float = 1.0 / 16.0
    nonisolated private static let fineStep: Float = 1.0 / 64.0

    nonisolated private static let NX_KEYTYPE_SOUND_UP: Int32 = 0
    nonisolated private static let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
    nonisolated private static let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
    nonisolated private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
    nonisolated private static let NX_KEYTYPE_MUTE: Int32 = 7

    /// System-defined event type. CGEventType has no public case for this
    /// (rawValue 14), so we force-unwrap once at type level.
    nonisolated private static let systemDefined = CGEventType(rawValue: 14)!

    /// Brightness keys are only ours to drive when the built-in panel is the
    /// SOLE display. With any external display attached (e.g. a Studio
    /// Display) we let the key pass through to macOS so it controls the right
    /// monitor — and, critically, so we never swallow the key and drive
    /// brightness on the wrong display. Our brightness ribbon is anchored at
    /// the physical notch, which only exists on the built-in panel anyway.
    nonisolated private static func shouldHandleBrightnessKeys() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count == 1 else { return false }
        var id = CGDirectDisplayID(0)
        var got: UInt32 = 0
        guard CGGetOnlineDisplayList(1, &id, &got) == .success, got == 1 else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Singleton-style weak reference so the C tap callback can hop back
    /// to the live instance without retaining it.
    nonisolated(unsafe) private static weak var active: MediaKeySuppressor?

    /// When macAudio is running it owns volume control (it syncs a master
    /// level across a multi-output set the system can't), so we pass volume
    /// and mute keys through to it and just render its broadcasts via
    /// MacAudioVolumeBridge. Read from the tap thread, written on main — a
    /// plain Bool flag, benign to race.
    nonisolated private static let macAudioBundleID = "com.erwinzhang.macAudio"
    nonisolated(unsafe) private static var macAudioRunning = false

    init(brightness: BrightnessActivitySource, volume: VolumeActivitySource) {
        self.brightness = brightness
        self.volume = volume
    }

    func start() {
        Self.active = self
        startMacAudioWatch()
        let trusted = AXIsProcessTrusted()
        NSLog("[MediaKeys] start() — AX trusted=%@", trusted ? "Y" : "N")
        if installTap() { return }
        // If we're already trusted but installTap still failed, prompting
        // is useless (the user already granted us — showing the system
        // dialog again would just spam them). Poll instead and surface the
        // failure mode in logs.
        if trusted {
            NSLog("[MediaKeys] trusted but tap install failed — polling without re-prompt")
        } else {
            NSLog("[MediaKeys] not trusted — prompting once + polling")
            if !promptedForAccess { promptForAccessibility() }
        }
        startTrustPolling()
    }

    func stop() {
        teardownTap()
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        if Self.active === self { Self.active = nil }
    }

    // MARK: - macAudio presence

    /// Track whether macAudio is running so the tap can cede volume/mute keys
    /// to it. Seed from the current running set, then keep it live via launch
    /// / terminate notifications.
    private func startMacAudioWatch() {
        guard workspaceObservers.isEmpty else { return }
        Self.macAudioRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.macAudioBundleID
        }
        let nc = NSWorkspace.shared.notificationCenter
        let update: (Notification, Bool) -> Void = { note, running in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.macAudioBundleID else { return }
            Self.macAudioRunning = running
        }
        workspaceObservers = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) {
                update($0, true)
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                update($0, false)
            },
        ]
    }

    // MARK: - Tap lifecycle

    private func installTap() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask = 1 << Self.systemDefined.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                guard let suppressor = MediaKeySuppressor.active else {
                    return Unmanaged.passUnretained(event)
                }
                return suppressor.handleNonisolated(type: type, event: event)
            },
            userInfo: nil
        ) else {
            NSLog("[MediaKeys] tapCreate returned nil despite AX trust — giving up")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        NSLog("[MediaKeys] suppression tap installed")
        return true
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Trust handling

    private func promptForAccessibility() {
        promptedForAccess = true
        NSLog("[MediaKeys] showing Accessibility prompt + system permission dialog")

        // Triggers the system prompt and registers the app under Accessibility.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // LSUIElement apps don't have a Dock icon, so a plain modal alert
        // can land behind other windows. Force-activate first so the user
        // actually sees the dialog.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "NotchApp needs Accessibility access"
        alert.informativeText = """
            To suppress the macOS brightness/volume HUD and show the notch \
            ribbon instead, enable NotchApp in System Settings → Privacy & \
            Security → Accessibility.

            The app keeps working without this — you'll just see both the \
            system HUD and the notch ribbon.
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
        NSLog("[MediaKeys] starting trust poll (every 2s)")
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                NSLog("[MediaKeys] poll tick — AX trusted=%@", trusted ? "Y" : "N")
                if self.installTap() {
                    self.trustPollTimer?.invalidate()
                    self.trustPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    // MARK: - Event handling

    /// Called from the CGEvent tap thread. We only need MainActor for the
    /// adjust/toggle calls — everything else here is pure parsing.
    nonisolated private func handleNonisolated(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let tap = self?.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemDefined else { return Unmanaged.passUnretained(event) }

        // Parse via NSEvent for the canonical subtype/data1 read. The raw
        // CGEventField path mew uses returns garbage for non-aux subtypes.
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let keyCode = Int32((data1 >> 16) & 0xFFFF)
        let keyFlags = data1 & 0xFFFF
        let stateNibble = (keyFlags & 0xFF00) >> 8
        let isKeyDown = stateNibble == 0xA
        let isKeyUp = stateNibble == 0xB

        switch keyCode {
        case Self.NX_KEYTYPE_SOUND_UP,
             Self.NX_KEYTYPE_SOUND_DOWN,
             Self.NX_KEYTYPE_MUTE,
             Self.NX_KEYTYPE_BRIGHTNESS_UP,
             Self.NX_KEYTYPE_BRIGHTNESS_DOWN:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        // Don't intercept brightness while an external display is attached —
        // let macOS handle it so the external monitor's brightness keeps
        // working and we never touch the wrong display.
        let isBrightness = keyCode == Self.NX_KEYTYPE_BRIGHTNESS_UP
            || keyCode == Self.NX_KEYTYPE_BRIGHTNESS_DOWN
        if isBrightness, !Self.shouldHandleBrightnessKeys() {
            return Unmanaged.passUnretained(event)
        }

        // Cede volume/mute keys to macAudio while it's running — it controls
        // volume (syncing a multi-output set) and broadcasts the result back
        // to our ribbon. We must not also drive or swallow the key.
        let isVolumeOrMute = keyCode == Self.NX_KEYTYPE_SOUND_UP
            || keyCode == Self.NX_KEYTYPE_SOUND_DOWN
            || keyCode == Self.NX_KEYTYPE_MUTE
        if isVolumeOrMute, Self.macAudioRunning {
            return Unmanaged.passUnretained(event)
        }

        if isKeyDown {
            let flags = event.flags
            let fine = flags.contains(.maskShift) && flags.contains(.maskAlternate)
            let step = fine ? Self.fineStep : Self.normalStep
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(keyCode: keyCode, step: step)
                }
            }
            return nil
        }
        if isKeyUp {
            // Swallow the matching keyUp so nothing downstream sees a
            // dangling release for an event we already consumed.
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func apply(keyCode: Int32, step: Float) {
        switch keyCode {
        case Self.NX_KEYTYPE_SOUND_UP:        volume.adjust(by: +step)
        case Self.NX_KEYTYPE_SOUND_DOWN:      volume.adjust(by: -step)
        case Self.NX_KEYTYPE_MUTE:            volume.toggleMute()
        case Self.NX_KEYTYPE_BRIGHTNESS_UP:   brightness.adjust(by: +step)
        case Self.NX_KEYTYPE_BRIGHTNESS_DOWN: brightness.adjust(by: -step)
        default: break
        }
    }
}
