import Combine
import SwiftUI

/// Queue + state machine driving the idle notch's content. Replaces
/// DynamicNotch's `NotchEngine` with a much leaner version — no
/// expand-on-tap, no dismissed-stack restore, no per-activity windowLink
/// callbacks. Just: show / update / hide live activities, and show
/// temporary notifications that auto-hide after a duration.
@MainActor
final class NotchActivityEngine: ObservableObject {
    @Published private(set) var model = NotchActivityModel()

    private var activeLiveActivities: [any NotchActivity] = []
    private var temporaryTask: Task<Void, Never>?
    private var temporaryTimerID = UUID()
    private var suspendedLiveActivity: (any NotchActivity)?
    private var isTransitioning = false

    /// Update the base size when the physical notch geometry changes.
    /// Called from the idle-pill host when it computes its frame.
    func updateBaseSize(_ size: CGSize) {
        guard model.baseSize != size else { return }
        model.baseSize = size
        model.updateToken = UUID()
    }

    /// Show or update a live activity. Same id = same activity (updates
    /// the visible properties without re-running the appear animation).
    /// Different id = the engine compares priorities and the winner takes
    /// the slot.
    func showLiveActivity(_ activity: any NotchActivity) {
        updateLiveStack(with: activity)

        // Same-id update: swap content in place, no transition.
        if model.liveActivity?.id == activity.id {
            withAnimation(NotchAnimations.contentUpdate) {
                model.liveActivity = activity
                model.updateToken = UUID()
            }
            return
        }

        // If a temporary notification is owning the screen, just remember
        // the new live activity — the engine restores the highest-priority
        // one once the temporary clears.
        if model.temporary != nil {
            suspendedLiveActivity = highestPriorityActivity
            return
        }

        // No competition: animate the new one in. If the incoming
        // activity isn't actually the highest-priority one (e.g. a low-pri
        // one fires while a higher-pri one is already active), defer to
        // the highest.
        let best = highestPriorityActivity
        guard best?.id != model.liveActivity?.id else {
            if let best, best.id == activity.id {
                // Same activity, fresh data.
                withAnimation(NotchAnimations.contentUpdate) {
                    model.liveActivity = best
                    model.updateToken = UUID()
                }
            }
            return
        }

        transition(
            hide: {
                withAnimation(NotchAnimations.contentHide) {
                    self.model.liveActivity = nil
                }
            },
            show: {
                withAnimation(NotchAnimations.contentShow) {
                    self.model.liveActivity = best
                    self.model.updateToken = UUID()
                }
            }
        )
    }

    /// Remove a live activity by id. If it was the visible one, the
    /// next-highest-priority active activity slides in.
    func hideLiveActivity(id: String) {
        activeLiveActivities.removeAll(where: { $0.id == id })

        guard model.liveActivity?.id == id else { return }

        let next = highestPriorityActivity
        if next?.id == model.liveActivity?.id { return }

        transition(
            hide: {
                withAnimation(NotchAnimations.contentHide) {
                    self.model.liveActivity = nil
                }
            },
            show: {
                if let next {
                    withAnimation(NotchAnimations.contentShow) {
                        self.model.liveActivity = next
                        self.model.updateToken = UUID()
                    }
                }
            }
        )
    }

    /// Show a temporary notification (charging plugged in, bluetooth
    /// connected, etc.). Preempts any current live activity for
    /// `duration` seconds, then restores the suspended live activity.
    func showTemporary(_ activity: any NotchActivity, duration: TimeInterval) {
        // Same-id rapid replay (e.g. plug→unplug→plug while still showing):
        // just refresh and restart the timer.
        if model.temporary?.id == activity.id {
            withAnimation(NotchAnimations.contentUpdate) {
                model.temporary = activity
                model.updateToken = UUID()
            }
            restartTemporaryTimer(duration: duration)
            return
        }

        transition(
            hide: {
                self.cancelTemporary()
                withAnimation(NotchAnimations.contentHide) {
                    if let live = self.model.liveActivity {
                        self.suspendedLiveActivity = live
                        self.model.liveActivity = nil
                    }
                    self.model.temporary = nil
                }
            },
            show: {
                withAnimation(NotchAnimations.contentShow) {
                    self.model.temporary = activity
                    self.model.updateToken = UUID()
                }
                self.restartTemporaryTimer(duration: duration)
            }
        )
    }

    /// Hide the current temporary notification ahead of its timer (or
    /// after the timer fires). Restores the highest-priority live
    /// activity that was suspended.
    func hideTemporary() {
        guard model.temporary != nil else { return }

        cancelTemporary()
        let restore = highestPriorityActivity

        transition(
            hide: {
                withAnimation(NotchAnimations.contentHide) {
                    self.model.temporary = nil
                }
            },
            show: {
                withAnimation(NotchAnimations.contentShow) {
                    self.model.liveActivity = restore
                    self.suspendedLiveActivity = nil
                    self.model.updateToken = UUID()
                }
            }
        )
    }

    // MARK: - Internals

    private var highestPriorityActivity: (any NotchActivity)? {
        activeLiveActivities.sorted { $0.priority > $1.priority }.first
    }

    private func updateLiveStack(with activity: any NotchActivity) {
        if let index = activeLiveActivities.firstIndex(where: { $0.id == activity.id }) {
            activeLiveActivities[index] = activity
        } else {
            activeLiveActivities.append(activity)
        }
    }

    /// Two-phase swap: hide content, wait one `hideShowDelay` beat, then
    /// run the show closure. Guards against overlapping transitions
    /// because two springs colliding on the same content swap visually
    /// like a glitch.
    private func transition(hide: @escaping () -> Void, show: @escaping () -> Void) {
        guard !isTransitioning else { return }
        isTransitioning = true

        DispatchQueue.main.async {
            hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchAnimations.hideShowDelay) {
                show()
                self.isTransitioning = false
            }
        }
    }

    private func cancelTemporary() {
        temporaryTask?.cancel()
        temporaryTask = nil
    }

    private func restartTemporaryTimer(duration: TimeInterval) {
        cancelTemporary()
        guard duration.isFinite else { return }

        let timerID = UUID()
        temporaryTimerID = timerID

        temporaryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.temporaryTimerID == timerID else { return }
                self.hideTemporary()
            }
        }
    }
}
