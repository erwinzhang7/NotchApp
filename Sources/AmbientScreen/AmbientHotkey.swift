import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey via Carbon's RegisterEventHotKey. No
/// third-party dependency and no Accessibility permission required (the
/// modern NSEvent.addGlobalMonitor approach would need it).
///
/// Default chord ⌃⌥⌘A — bound at construction time and held for the
/// hotkey's lifetime. Phase 1 doesn't ship a rebinding UI; that's a
/// follow-up.
@MainActor
final class AmbientHotkey {
    /// Fires on every press of the registered chord.
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private var id: UInt32 = 0

    /// keyCode is a Carbon kVK_* constant (e.g. kVK_ANSI_A = 0).
    /// modifiers is a bitfield of Carbon flags (cmdKey, optionKey, controlKey, shiftKey).
    init(keyCode: UInt32 = UInt32(kVK_ANSI_A),
         modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey)) {
        Self.nextID += 1
        self.id = Self.nextID

        // Install the application-level event handler the first time we're
        // registered. The handler dispatches to the correct AmbientHotkey
        // instance via a static registry.
        Self.ensureHandlerInstalled()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E544348), id: id) // 'NTCH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            self.hotKeyRef = ref
            Self.registry[id] = self
        }
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        Self.registry.removeValue(forKey: id)
    }

    // MARK: - Static dispatch

    nonisolated(unsafe) private static var registry: [UInt32: AmbientHotkey] = [:]
    nonisolated(unsafe) private static var handlerInstalled = false

    private static func ensureHandlerInstalled() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            if err == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AmbientHotkey.registry[id]?.onFire?()
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
