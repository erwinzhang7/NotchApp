import SwiftUI

/// Placeholder for the lyrics column while a fetch is in flight.
/// Picks one of 20 playful messages at random per loading session
/// — beats a static "Loading..." or a spinner with no personality.
/// Subtly pulses so it's visibly alive, even while LRCLIB chews
/// through its 5-second response window.
///
/// Message rotates per `trackKey`: a fresh fetch gets a fresh
/// message (deterministically chosen so a given track always shows
/// the same one during this session — feels intentional, not
/// random-on-every-redraw).
struct LyricsLoadingView: View {
    let trackKey: String
    let style: LyricsScrollingView.Style

    @State private var pulse: Bool = false

    private static let messages: [String] = [
        "Cooking…",
        "Chasing it down…",
        "Asking the band…",
        "Hunting bars…",
        "Tuning in…",
        "Eavesdropping…",
        "Decoding the chorus…",
        "Stealing the words…",
        "Negotiating with LRCLIB…",
        "Reading between bars…",
        "Phoning the songwriter…",
        "Bribing the producer…",
        "Translating from vinyl…",
        "Conjuring…",
        "Mixing it in…",
        "Tracking syllables…",
        "Borrowing from karaoke…",
        "Asking the algorithm nicely…",
        "Pulling strings…",
        "Calling it down from the cloud…",
    ]

    /// Deterministic per-trackKey so the message doesn't shuffle on
    /// every SwiftUI re-render — the user sees one stable message
    /// per fetch, picked from the pool by hash.
    private var message: String {
        var hasher = Hasher()
        hasher.combine(trackKey)
        let h = abs(hasher.finalize())
        return Self.messages[h % Self.messages.count]
    }

    var body: some View {
        Text(message)
            .font(.system(
                size: style.inactiveFontSize,
                weight: .medium,
                design: .rounded
            ))
            .foregroundStyle(.white.opacity(pulse ? 0.55 : 0.32))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
