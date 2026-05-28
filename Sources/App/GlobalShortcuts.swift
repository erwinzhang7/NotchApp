import KeyboardShortcuts

/// All user-bindable global shortcuts. Patterned after boring.notch's
/// `ShortcutConstants.swift`: every shortcut is a typed
/// `KeyboardShortcuts.Name` so the settings UI can render a recorder
/// row per name and the library handles persistence + (un)registration
/// automatically.
///
/// Defaults are deliberately empty — users opt in by recording a binding
/// in Settings. The previous bespoke ⌃⌥⌘P "panic" hotkey is gone; the
/// closest replacement is `togglePin`, which the user can bind to
/// whatever they like.
extension KeyboardShortcuts.Name {
    static let togglePin = Self("togglePin")
    static let showClipboardHistory = Self("showClipboardHistory")
    static let pasteTopClip = Self("pasteTopClip")
    static let airDropTopShelfItem = Self("airDropTopShelfItem")
    static let clearShelf = Self("clearShelf")
    static let openSettings = Self("openSettings")
}

extension KeyboardShortcuts.Name {
    /// All shortcuts in display order. Drives both the registration loop
    /// in AppDelegate and the settings UI's recorder list.
    static let all: [(KeyboardShortcuts.Name, String)] = [
        (.togglePin, "Toggle notch pin"),
        (.showClipboardHistory, "Show clipboard history"),
        (.pasteTopClip, "Paste most recent clip"),
        (.airDropTopShelfItem, "AirDrop top shelf item"),
        (.clearShelf, "Clear shelf"),
        (.openSettings, "Open Settings…"),
    ]
}
