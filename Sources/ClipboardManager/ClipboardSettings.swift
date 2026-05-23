import Combine
import Foundation

/// User preferences for clipboard capture and history retention.
/// These are PREFERENCES (UserDefaults) — distinct from clipboard CONTENT, which is RAM-only.
final class ClipboardSettings: ObservableObject {
    enum AutoClearInterval: String, CaseIterable, Identifiable {
        case never
        case hour
        case day
        case week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .never: return "Never"
            case .hour:  return "1 Hour"
            case .day:   return "1 Day"
            case .week:  return "1 Week"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .never: return nil
            case .hour:  return 60 * 60
            case .day:   return 60 * 60 * 24
            case .week:  return 60 * 60 * 24 * 7
            }
        }
    }

    @Published var autoClearInterval: AutoClearInterval {
        didSet { defaults.set(autoClearInterval.rawValue, forKey: Keys.autoClear) }
    }
    @Published var captureText: Bool {
        didSet { defaults.set(captureText, forKey: Keys.captureText) }
    }
    @Published var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Keys.captureImages) }
    }
    @Published var captureFiles: Bool {
        didSet { defaults.set(captureFiles, forKey: Keys.captureFiles) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let autoClear     = "clipboard.autoClearInterval"
        static let captureText   = "clipboard.captureText"
        static let captureImages = "clipboard.captureImages"
        static let captureFiles  = "clipboard.captureFiles"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoClear:     AutoClearInterval.never.rawValue,
            Keys.captureText:   true,
            Keys.captureImages: true,
            Keys.captureFiles:  true,
        ])
        let rawInterval = defaults.string(forKey: Keys.autoClear) ?? AutoClearInterval.never.rawValue
        self.autoClearInterval = AutoClearInterval(rawValue: rawInterval) ?? .never
        self.captureText   = defaults.bool(forKey: Keys.captureText)
        self.captureImages = defaults.bool(forKey: Keys.captureImages)
        self.captureFiles  = defaults.bool(forKey: Keys.captureFiles)
    }
}
