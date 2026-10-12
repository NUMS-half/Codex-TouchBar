import Foundation

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("CodexTouchBar.PrefsDidChange")
    static let buttonsDidChange = Notification.Name("CodexTouchBar.ButtonsDidChange")
    static let alertsDidChange = Notification.Name("CodexTouchBar.AlertsDidChange")

    private let defaults: UserDefaults
    private let buttonsKey = "touchBarButtons.v1"
    private let touchBarEnabledKey = "touchBarEnabled"
    private let refreshIntervalKey = "refreshIntervalSeconds"
    private let loginSetupAttemptedKey = "loginSetupAttempted"

    static let refreshIntervals: [TimeInterval] = [30, 60, 120, 300, 600]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var usageAlertOptions: UsageAlertOptions {
        get {
            guard let data = defaults.data(forKey: "usageAlerts.options.v1"),
                  let options = try? JSONDecoder().decode(UsageAlertOptions.self, from: data) else { return .init() }
            return options
        }
        set {
            guard newValue != usageAlertOptions, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "usageAlerts.options.v1")
            NotificationCenter.default.post(name: Self.alertsDidChange, object: self)
        }
    }

    var usageAlertState: Data? {
        get { defaults.data(forKey: "usageAlerts.state.v1") }
        set { defaults.set(newValue, forKey: "usageAlerts.state.v1") }
    }

    var touchBarConfiguration: TouchBarConfiguration {
        get { TouchBarConfiguration.decode(defaults.data(forKey: buttonsKey)) }
        set {
            guard newValue != touchBarConfiguration, let data = newValue.encoded() else { return }
            defaults.set(data, forKey: buttonsKey)
            NotificationCenter.default.post(name: Self.buttonsDidChange, object: self)
        }
    }

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
