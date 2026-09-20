import Foundation

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("CodexTouchBar.PrefsDidChange")

    private let defaults = UserDefaults.standard
    private let touchBarEnabledKey = "touchBarEnabled"
    private let refreshIntervalKey = "refreshIntervalSeconds"
    private let loginSetupAttemptedKey = "loginSetupAttempted"

    static let refreshIntervals: [TimeInterval] = [30, 60, 120, 300, 600]

    var touchBarEnabled: Bool {
        get { defaults.object(forKey: touchBarEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: touchBarEnabledKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.object(forKey: refreshIntervalKey) as? NSNumber
            let value = stored.map { TimeInterval($0.doubleValue) } ?? 30
            return Self.refreshIntervals.contains(value) ? value : 30
        }
        set {
            guard Self.refreshIntervals.contains(newValue) else { return }
            defaults.set(newValue, forKey: refreshIntervalKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    static func refreshIntervalTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 30: return "30 秒"
        case 60: return "1 分钟"
        default: return "\(Int(interval / 60)) 分钟"
        }
    }

    var hasAttemptedLoginSetup: Bool {
        get { defaults.bool(forKey: loginSetupAttemptedKey) }
        set { defaults.set(newValue, forKey: loginSetupAttemptedKey) }
    }
}
