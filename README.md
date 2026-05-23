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

Each feature module is a single stub file with a one-line doc comment and
a `// TODO`. They will be filled in one at a time in follow-up sessions.

## Attribution

The shell/shelf approach is inspired by
[NotchDrop](https://github.com/Lakr233/NotchDrop) by Lakr233 (MIT).
NotchApp is an independent reimplementation; no code is copied.

## License

MIT — see [LICENSE](LICENSE).
