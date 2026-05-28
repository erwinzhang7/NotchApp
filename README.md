# NotchApp

A macOS notch utility that turns the MacBook notch into a live control surface: Dynamic Island-style activities, clipboard history, drag-and-drop file shelf, media controls, a calendar and reminders dashboard, lock-screen presentation, and file conversion — all tucked behind the notch, out of the way until you need them.

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

**Dynamic Island Activities** — An always-visible compact pill displays now-playing while audio is active and temporary ribbons for brightness, output volume, AC connection, battery thresholds, and Bluetooth audio-device connections.

**Lock Screen Widget** — An optional music card and lock/unlock notch indicator render during lock presentation or configured system idle time. Unlock uses its own lock-indicator animation path rather than the activity engine.

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
├── AmbientScreen/        Optional lock-screen music + lock/unlock indicator
├── Calendar/             EventKit wrapper, CalendarService, CalendarView
├── Reminders/            EventKit wrapper, RemindersService, RemindersView
├── Conversion/           Converter registry, ImageIO capability self-test
└── Vendor/
    └── MediaRemoteAdapter/   Bundled Perl adapter + MediaRemoteAdapter.framework
```

### NotchShell

A borderless, non-activating `NSPanel` floating at the status-bar window level, joined to all Spaces. Geometry is computed from `NSScreen.safeAreaInsets.top` (physical notch height) and the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (notch width). On displays without a notch the panel falls back to a fixed size pinned top-center, just below the menu bar. Re-positioned on `NSApplication.didChangeScreenParametersNotification` to survive display changes and sleep/wake.

The app has three notch-position presentation paths:

1. The interactive shell expands on hover, click-to-pin, or file drag/drop.
2. The idle Dynamic Island-style pill hosts activities from power, Bluetooth audio connections, now-playing, built-in display brightness, and current output volume.
3. The optional lock-screen presentation uses a separate panel and observer route for pre-lock, lock, idle, and the post-unlock icon/shrink animation.

### In-memory privacy model

Clipboard content exists only in RAM. `ClipboardStore` is a plain Swift array with no persisted clipboard payload; clipboard content does not survive a quit. The file shelf holds security-scoped bookmark references in memory rather than copying file bytes. Preferences and lyrics cache data may be persisted separately.

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

### Self-sign with your own certificate (recommended for stable permissions)

If you installed a pre-built `.app` from another machine, it was signed with that machine's local certificate, which your Mac doesn't trust. Re-signing with a self-made certificate on your own Mac gives the app a stable identity, so Accessibility / Screen Recording / Automation permissions stick across updates instead of being re-prompted every launch.

**1. Create a self-signed code-signing certificate (one time, ~1 minute):**

Open **Keychain Access** (it's in `/Applications/Utilities/` — Spotlight it). In the menu bar: **Keychain Access → Certificate Assistant → Create a Certificate…**

- **Name:** `NotchApp Self-Signed` (any name works — remember it exactly)
- **Identity Type:** Self Signed Root
- **Certificate Type:** Code Signing
- ✅ Check **Let me override defaults** (this is the step Apple hides — without it the cert is created with the wrong key usage and `codesign` will reject it with "no identity found")
- Click **Continue** through each panel, accepting defaults:
  - Serial Number / Validity — leave defaults (default 365 days is fine, bump it higher if you want)
  - Certificate Information — fill in anything or leave blank
  - **Key Pair Information** — Algorithm: RSA, Key Size: 2048
  - **Key Usage Extension** — make sure **Signature** is checked
  - **Extended Key Usage Extension** — make sure **Code Signing** is checked
  - Skip the remaining panels with **Continue**
  - Keychain: **login**
- Click **Create**, then **Done**.

**2. Trust it for code signing:**

In Keychain Access, switch to the **login** keychain → **My Certificates**. Double-click your new `NotchApp Self-Signed` cert → expand **Trust** → set **Code Signing** to **Always Trust**. Close the window (you'll be prompted for your login password to save the trust setting).

**3. Verify the identity is usable:**

```sh
security find-identity -v -p codesigning
```

You should see `NotchApp Self-Signed` in the list. If it doesn't appear, the "override defaults" step was skipped — delete the cert and recreate it.

**4. Sign the app and clear quarantine:**

```sh
codesign --force --deep --sign "NotchApp Self-Signed" /Applications/NotchApp.app
xattr -dr com.apple.quarantine /Applications/NotchApp.app
```

Verify it took:

```sh
codesign -dv /Applications/NotchApp.app
```

The `Authority=` line should show your cert name.

**5. First launch (macOS 15 Sequoia changed this):**

On macOS 15, Apple removed the right-click → Open shortcut for unsigned/self-signed apps. The new flow:

1. Double-click `NotchApp.app` — macOS will block it with *"not opened because Apple could not verify…"*. Click **Done** (do NOT click Move to Trash).
2. Open **System Settings → Privacy & Security**, scroll to the bottom.
3. You'll see *"NotchApp was blocked to protect your Mac"* — click **Open Anyway**.
4. Authenticate, then in the next dialog click **Open Anyway** again.

After this first approval, launches are normal.

**Re-signing after an update:** if you replace the `.app` with a new build later, re-run the `codesign` + `xattr` commands from step 4. Use the same certificate name and your granted Accessibility / Screen Recording / Automation permissions will persist instead of being wiped.

### Permission prompts

NotchApp may request the following permissions as the related feature first becomes active:

| Permission | When | Why |
|---|---|---|
| **Calendars** | First open of Ambient tab → Grant Access | Displays today's events via EventKit |
| **Reminders** | First open of Ambient tab → Grant Access | Displays scheduled reminders via EventKit |
| **Automation (Spotify)** | First scrub of a Spotify track | Sends `set player position to` via AppleScript |
| **Bluetooth** | Activity monitoring begins / Bluetooth is first accessed | Displays an activity when a named audio device connects |

These permissions are optional. Denying one disables or limits only its related integration.

---

## Privacy

- **Clipboard history** is held in RAM only. Its content is lost on quit by design.
- **File shelf** stores security-scoped bookmark URLs — pointers to files you already own — not copies of file content.
- **Calendar and reminders** data is read from EventKit on-device. It is never transmitted anywhere.
- **Media metadata** (track title, artist, artwork) is received from the local MediaRemote subsystem. It stays local.
- **Lyrics** are prefetched from LRCLIB for playing tracks so they are ready when opened, and are cached locally by the lyrics provider.
- There is no analytics or crash reporting included in the app.

---

## Screenshots

<!-- PLACEHOLDER — add screenshots below once available -->
<!-- ![Clipboard tab](assets/screenshot-clipboard.png) -->
<!-- ![Ambient tab](assets/screenshot-ambient.png) -->
<!-- ![File shelf](assets/screenshot-shelf.png) -->

---

## Acknowledgements

- **[DynamicNotch](https://github.com/jackson-storm/DynamicNotch)** by Evgeniy Petrukovich and contributors (GPL-3.0) — adapted source and behavior for the activity model/engine, notch shape and animation work, activity views, lock observation, artwork/equalizer handling, and lyrics components. NotchApp is distributed under GPL-3.0 accordingly.
- **[Atoll](https://github.com/Ebullioscopic/Atoll)** by Ebullioscopic and contributors (GPL-3.0) — source of adapted lock-screen/panel presentation patterns and Dynamic Island layout behavior.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** by Lakr233 (MIT) — inspiration for the notch-panel shell and file shelf approach. NotchApp is an independent reimplementation; no source is copied.
- **mediaremote-adapter** by Jonas van den Berg and contributors (BSD 3-Clause) — the bundled Perl adapter and `MediaRemoteAdapter.framework` that bridge the macOS 15.4+ MediaRemote entitlement lockdown. See `Vendor/MediaRemoteAdapter/MediaRemoteAdapter-LICENSE.txt`.
- **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam (GPL-3.0) — referenced for media integration approach; it is also part of the GPL-3.0 lineage documented by Atoll.

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
