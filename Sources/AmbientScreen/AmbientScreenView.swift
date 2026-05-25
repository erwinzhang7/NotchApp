import SwiftUI

/// SwiftUI root for the ambient screen window. Layered: blurred-artwork
/// backdrop, then the layout (glass cards). ESC dismisses via the
/// `onDismiss` callback passed from the window controller.
struct AmbientScreenView: View {
    @ObservedObject private var musicState = MediaControls.shared.state
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            AmbientBackdrop(state: musicState)
            AmbientScreenLayout()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .background(
            // Invisible key-handler: catches ESC at the window level so
            // the user can always escape without hunting for a button.
            KeyHandler(onEscape: onDismiss)
        )
    }
}

/// AppKit bridge to listen for ESC presses inside the ambient window.
private struct KeyHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let v = KeyHandlingView()
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.onEscape = onEscape
    }
}

final class KeyHandlingView: NSView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // kVK_Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
