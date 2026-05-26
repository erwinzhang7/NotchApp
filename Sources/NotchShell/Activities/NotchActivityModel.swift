import Foundation
import SwiftUI

/// Current state of the idle notch as a single value. Mirrors
/// DynamicNotch's `NotchModel` but stripped to what the lean engine
/// needs: one live activity + one temporary notification + the base
/// idle size. No expanded variants, no stroke colors, no priorities
/// stored on the model itself (the engine sorts at queue time).
struct NotchActivityModel: Equatable {
    var liveActivity: (any NotchActivity)? = nil
    var temporary: (any NotchActivity)? = nil

    /// Base size of the idle pill — set by the host view based on the
    /// physical notch geometry. Activities grow from here.
    var baseSize: CGSize = .init(width: 200, height: 32)

    /// What should actually render right now. Temporary notifications
    /// preempt live activities (charger plug shows even if music is also
    /// playing).
    var current: (any NotchActivity)? { temporary ?? liveActivity }

    /// Size to render at — base if nothing is active, otherwise sized
    /// from the current activity.
    var size: CGSize {
        guard let current else { return baseSize }
        return current.size(base: baseSize)
    }

    /// Stable token so a no-identity-change update (e.g. battery %
    /// climbed) still re-runs animations on dependent properties.
    var updateToken: UUID = UUID()

    static func == (lhs: NotchActivityModel, rhs: NotchActivityModel) -> Bool {
        lhs.current?.id == rhs.current?.id &&
        lhs.baseSize == rhs.baseSize &&
        lhs.updateToken == rhs.updateToken
    }
}
