# NotchApp

An all-in-one macOS utility anchored to the MacBook notch: file shelf, media
controls, and a local clipboard manager.

Built in Swift + SwiftUI. Runs as a menu-bar agent (no dock icon).

## Requirements

- macOS 15+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```sh
xcodegen           # generate NotchApp.xcodeproj from project.yml
open NotchApp.xcodeproj
```

Run the `NotchApp` scheme. The app launches as an `LSUIElement` agent and
attaches an empty panel under the notch on the active display.

## Architecture

The project is split into one shell module and three feature modules. Only
the shell is implemented in the initial scaffold; the feature modules are
stubs.

```
Sources/
├── App/                 SwiftUI @main entry + NSApplicationDelegate
├── NotchShell/          NSPanel anchored under the notch (this is the host surface)
├── FileShelf/           [stub] drag-and-drop file shelf
├── MediaControls/       [stub] now-playing + transport
└── ClipboardManager/    [stub] local clipboard history
```

### NotchShell

`NotchShell` owns a borderless, non-activating `NSPanel` that floats at the
status-bar window level and joins all spaces. Geometry is computed from
`NSScreen.safeAreaInsets.top` (notch height) and the gap between
`auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (notch width). On
displays without a notch (external monitors, older MacBooks) the panel
falls back to a fixed size pinned to the top-center of the screen, just
below the menu bar. The panel is re-positioned on
`NSApplication.didChangeScreenParametersNotification` so display changes
(plugging in a monitor, sleep/wake) keep it placed correctly.

### Feature modules

- **ClipboardManager** — implemented. Polls `NSPasteboard.general` at 0.5 s
  intervals via `changeCount`. Captures text, images (downscaled thumbnail
  + full image in RAM, capped at 20 MB), and file copies (stored as
  bookmark references, never as byte copies). Exposes a SwiftUI history
  list (paste-on-select + search) and a Settings pane (auto-clear
  interval, per-type capture toggles, clear-now). See the privacy section
  below.
- **FileShelf**, **MediaControls** — still stubs, filled in next.

### Privacy: clipboard history is in-memory only

The single load-bearing privacy rule of this app:

> **Clipboard history is never written to disk.** No SQLite, no files, no
> `UserDefaults` entry holds clipboard content. History lives in RAM and
> dies on app quit.

What this means concretely:

- The only thing `ClipboardManager` persists is *preferences* — the
  auto-clear interval and the per-type capture toggles. Those go in
  `UserDefaults`. Clipboard *content* does not.
- File copies are stored as URL bookmarks, not byte copies. The app
  remembers *where* the file was so it can re-copy the reference later;
  it never duplicates file contents.
- Pasteboard items flagged `org.nspasteboard.ConcealedType` (the
  convention password managers use) and `org.nspasteboard.TransientType`
  are skipped at capture time — they never enter history.
- Single images larger than ~20 MB are skipped entirely rather than
  truncated, to bound RAM growth.

## Attribution

The shell/shelf approach is inspired by
[NotchDrop](https://github.com/Lakr233/NotchDrop) by Lakr233 (MIT).
NotchApp is an independent reimplementation; no code is copied.

## License

MIT — see [LICENSE](LICENSE).
