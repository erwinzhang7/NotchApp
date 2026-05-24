# NotchApp

A macOS notch utility that turns the MacBook notch into a live control surface: clipboard history, drag-and-drop file shelf, media controls, a calendar and reminders dashboard, and file conversion — all tucked behind the notch, out of the way until you need them.

Built in Swift + SwiftUI. Runs as a menu-bar agent (no dock icon). macOS 15+.

---

<!-- SCREENSHOT / GIF PLACEHOLDER — add a demo GIF or screenshot here -->
<!-- Example: ![Demo](assets/demo.gif) -->

---

## Features

**Clipboard Manager** — Tracks your last N clipboard entries (text, images, files) across the session. History is held entirely in RAM and discarded on quit — never written to disk, no database, no file. Password-manager entries (`org.nspasteboard.ConcealedType`) and transient items are silently skipped at capture time.

**File Shelf** — A temporary staging area for files you're working with. Drag files onto the notch panel to park them; drag them back out to use. File references are stored as security-scoped bookmarks, not byte copies — the app remembers where files are without duplicating content.

**Media Controls** — Shows the current track (artwork, title, artist, elapsed/duration scrubber) and exposes play/pause, previous, next. Seeks are routed per-player: MediaRemote for most apps, direct AppleScript (`set player position to`) for Spotify since Spotify silently ignores the MediaRemote seek path.

**Ambient Dashboard** — A glanceable panel showing today's calendar events and scheduled reminders alongside now-playing. Calendar and reminder data stay on-device via EventKit; nothing is transmitted externally.

**File Conversion** — Right-click a shelved image or PDF to convert it. Output formats are capability-tested at launch against the running ImageIO stack — only formats the current macOS build can actually encode appear in the menu, so you can't pick a target that would silently fail.

---

## Architecture

```
Sources/
├── App/                  @main entry, AppDelegate, SettingsView
├── NotchShell/           NSPanel host — geometry, state, layout, shell view
├── ClipboardManager/     Pasteboard monitor, in-memory store, history UI
├── FileShelf/            Drag-drop shelf, security-scoped bookmarks
├── MediaControls/        Now-playing state, transport, per-player seek routing
├── AmbientDashboard/     Layout + settings for the ambient pane
├── Calendar/             EventKit wrapper, CalendarService, CalendarView
├── Reminders/            EventKit wrapper, RemindersService, RemindersView
├── Conversion/           Converter registry, ImageIO capability self-test
└── Vendor/
    └── MediaRemoteAdapter/   Bundled Perl adapter + MediaRemoteAdapter.framework
```

### NotchShell

A borderless, non-activating `NSPanel` floating at the status-bar window level, joined to all Spaces. Geometry is computed from `NSScreen.safeAreaInsets.top` (physical notch height) and the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (notch width). On displays without a notch the panel falls back to a fixed size pinned top-center, just below the menu bar. Re-positioned on `NSApplication.didChangeScreenParametersNotification` to survive display changes and sleep/wake.

### In-memory privacy model

Clipboard content and file shelf entries exist only in RAM. `ClipboardStore` and `FileShelfStore` are plain Swift arrays — no SQLite, no `UserDefaults` payload, no file writes for content. Only user *preferences* (auto-clear interval, capture toggles) are persisted. This is load-bearing: the app can make a hard guarantee that clipboard content doesn't survive a quit.

### MediaRemote entitlement lockdown and the Perl adapter

Starting with macOS 15.4, Apple added an entitlement gate to the private `MediaRemote.framework`. Apps without the entitlement can no longer dlopen it directly. Rather than go dark on now-playing data, NotchApp ships a bundled helper: `Vendor/MediaRemoteAdapter/mediaremote-adapter.pl`, a Perl script that runs in a subprocess with the companion `MediaRemoteAdapter.framework` (which holds the entitlement). The Swift layer spawns this script as a long-lived `stream` process and parses its JSON-line stdout — track metadata, artwork (base64), elapsed time, playback state. Transport commands go back via short-lived `send` invocations. If the adapter fails to start (broken bundle, future macOS change), the UI degrades gracefully to a "media unavailable" state rather than crashing.

### Per-player seek routing

Scrubber seeks go through a three-tier router in `MediaControls.seek(toSeconds:)`:

1. **Spotify** (`com.spotify.client`) → AppleScript `tell application "Spotify" to set player position to N`. Spotify silently ignores the MediaRemote set-elapsed-time path, so this tier is hardcoded.
2. **Everything else** → MediaRemote `send setElapsedTime` via the adapter subprocess.
3. **Capability detection** — if a seek fails with a non-permission error (the player genuinely rejects it), the bundle ID is added to `seekUnsupportedSources` and the UI permanently swaps the scrubber to display-only for that player. Permission errors (AppleScript `-1743`/`-1744`) are not counted against the player — the scrubber stays interactive while the user resolves the Automation prompt.

### Conversion capability self-test

At launch, `ImageEncodingCapability` attempts to encode a 1×1 pixel test image in every candidate format using the same ImageIO pipeline the converter will use at runtime. Only formats that pass are exposed in the UI. This means WebP, HEIF, and other conditionally-supported formats appear only when the running macOS build can actually write them.

---

## Installation

### Homebrew (recommended)

```sh
brew install erwinzhang7/notchapp/notchapp
```

The tap is at [github.com/erwinzhang7/homebrew-notchapp](https://github.com/erwinzhang7/homebrew-notchapp).

### Build from source

Requirements: macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/erwinzhang7/NotchApp.git
cd NotchApp
xcodegen generate
open NotchApp.xcodeproj
```

Select the `NotchApp` scheme and build (⌘B) or run (⌘R). The app launches as an `LSUIElement` agent — no dock icon; look for the notch panel on your built-in display.

---

## First Launch & Permissions

### Gatekeeper (unsigned app)

NotchApp is not notarized. macOS will block it on first open. Two ways around this:

**Option A — right-click open:**
Right-click `NotchApp.app` in Finder → Open → Open (in the dialog that appears).

**Option B — clear quarantine:**
```sh
xattr -dr com.apple.quarantine /Applications/NotchApp.app
```

### Permission prompts

NotchApp will request the following permissions on first use — never at launch without user action:

| Permission | When | Why |
|---|---|---|
| **Calendars** | First open of Ambient tab → Grant Access | Displays today's events via EventKit |
| **Reminders** | First open of Ambient tab → Grant Access | Displays scheduled reminders via EventKit |
| **Automation (Spotify)** | First scrub of a Spotify track | Sends `set player position to` via AppleScript |

All three are optional. Denying any of them leaves the rest of the app fully functional.

---

## Privacy

- **Clipboard history** is held in RAM only. Nothing is written to disk, no network calls are made, no telemetry exists. Content is lost on quit by design.
- **File shelf** stores security-scoped bookmark URLs — pointers to files you already own — not copies of file content.
- **Calendar and reminders** data is read from EventKit on-device. It is never transmitted anywhere.
- **Media metadata** (track title, artist, artwork) is received from the local MediaRemote subsystem. It stays local.
- There is no analytics, no crash reporting, no network activity of any kind.

---

## Screenshots

<!-- PLACEHOLDER — add screenshots below once available -->
<!-- ![Clipboard tab](assets/screenshot-clipboard.png) -->
<!-- ![Ambient tab](assets/screenshot-ambient.png) -->
<!-- ![File shelf](assets/screenshot-shelf.png) -->

---

## Acknowledgements

- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** by Lakr233 (MIT) — inspiration for the notch-panel shell and file shelf approach. NotchApp is an independent reimplementation; no source is copied.
- **mediaremote-adapter** by Jonas van den Berg and contributors (BSD 3-Clause) — the bundled Perl adapter and `MediaRemoteAdapter.framework` that bridge the macOS 15.4+ MediaRemote entitlement lockdown. See `Vendor/MediaRemoteAdapter/MediaRemoteAdapter-LICENSE.txt`.
- **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam (GPL-2.0) — referenced for media integration approach. Not copied, not linked; GPL does not propagate to NotchApp.

---

## License

MIT — see [LICENSE](LICENSE).
