import SwiftUI

/// Composition view for the Ambient tab: compact music view always
/// pinned at the top, optional bottom row driven by AmbientSettings.
///
/// State machine (bottom row):
///   - both ON   → HStack: Reminders (left)  | Calendar (right)
///   - calendar  → Calendar fills the bottom
///   - reminders → Reminders fills the bottom
///   - both OFF  → bottom row removed entirely; the panel shrinks
///                 (NotchWindowController observes the same toggles and
///                  resizes the NSPanel frame, so there's no empty space).
struct AmbientDashboardView: View {
    @ObservedObject private var ambient    = AmbientSettings.shared
    @ObservedObject private var musicState = MediaControls.shared.state
    @ObservedObject private var calendar         = CalendarManager.shared.service
    @ObservedObject private var calendarSettings = CalendarManager.shared.settings
    @ObservedObject private var reminders         = RemindersManager.shared.service
    @ObservedObject private var remindersSettings = RemindersManager.shared.settings

    /// Music view's pinned height in the dashboard (top half). Sized so
    /// the centered music block (~118pt — 90pt art + 24pt vertical
    /// padding) sits with ~20pt breathing room above and below, without
    /// the old empty-space gulf.
    /// Stay in sync with NotchWindowController.ambientMusicHeight.
    static let musicHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingView(
                state: musicState,
                adapter: MediaControls.shared.adapter
            )
            .frame(height: Self.musicHeight)

            if showBottomRow {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                bottomRow
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ambient.showCalendar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ambient.showReminders)
    }

    private var showBottomRow: Bool {
        ambient.showCalendar || ambient.showReminders
    }

    @ViewBuilder
    private var bottomRow: some View {
        switch (ambient.showCalendar, ambient.showReminders) {
        case (true, true):
            HStack(spacing: 0) {
                RemindersView(service: reminders, settings: remindersSettings)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.5)
                CalendarView(service: calendar, settings: calendarSettings)
                    .frame(maxWidth: .infinity)
            }
        case (true, false):
            CalendarView(service: calendar, settings: calendarSettings)
        case (false, true):
            RemindersView(service: reminders, settings: remindersSettings)
        case (false, false):
            EmptyView()
        }
    }
}
