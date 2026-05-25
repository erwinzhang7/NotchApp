import SwiftUI

/// iPad-style composition for the ambient screen. Left sidebar = clock +
/// optional calendar / reminders cards (driven by AmbientSettings); right
/// region = centered large now-playing card.
struct AmbientScreenLayout: View {
    @ObservedObject private var ambient = AmbientSettings.shared
    @ObservedObject private var musicState = MediaControls.shared.state
    @ObservedObject private var calendar         = CalendarManager.shared.service
    @ObservedObject private var calendarSettings = CalendarManager.shared.settings
    @ObservedObject private var reminders         = RemindersManager.shared.service
    @ObservedObject private var remindersSettings = RemindersManager.shared.settings

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            sidebar
                .frame(width: 320)

            GlassCard {
                BigNowPlayingView(
                    state: musicState,
                    adapter: MediaControls.shared.adapter
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(48)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 20) {
            GlassCard {
                ClockCardView()
                    .padding(20)
            }

            if ambient.showCalendar {
                GlassCard {
                    CalendarView(service: calendar, settings: calendarSettings)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if ambient.showReminders {
                GlassCard {
                    RemindersView(service: reminders, settings: remindersSettings)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ambient.showCalendar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ambient.showReminders)
    }
}

/// Big clock + date card. Refreshes every second via TimelineView so it
/// stays accurate without an external timer.
struct ClockCardView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                Text(timeString(for: ctx.date))
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(dateString(for: ctx.date))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }

    private func dateString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}

/// Glass-effect container: NSVisualEffectView wrapped in a SwiftUI shape
/// with a faint inner stroke. Approximates the macOS 26 / Liquid Glass
/// look on macOS 15.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}

/// Bridge from NSVisualEffectView to SwiftUI.
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
