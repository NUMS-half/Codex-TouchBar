import Foundation

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("CodexTouchBar.PrefsDidChange")
    static let buttonsDidChange = Notification.Name("CodexTouchBar.ButtonsDidChange")
    static let refreshDidChange = Notification.Name("CodexTouchBar.RefreshDidChange")
    static let alertsDidChange = Notification.Name("CodexTouchBar.AlertsDidChange")

    private let defaults: UserDefaults
    private enum Key {
        static let buttons = "touchBarButtons.v1"
        static let touchBarEnabled = "touchBarEnabled"
        static let legacyRefreshInterval = "refreshIntervalSeconds"
        static let refreshPolicy = "quotaRefreshPolicy.v1"
        static let loginSetupAttempted = "loginSetupAttempted"
        static let alertOptions = "usageAlerts.options.v1"
        static let alertState = "usageAlerts.state.v1"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var usageAlertOptions: UsageAlertOptions {
        get {
            guard let data = defaults.data(forKey: Key.alertOptions),
                  let options = try? JSONDecoder().decode(UsageAlertOptions.self, from: data) else { return .init() }
            return options
        }
        set {
            guard newValue != usageAlertOptions, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.alertOptions)
            NotificationCenter.default.post(name: Self.alertsDidChange, object: self)
        }
    }

    var usageAlertState: Data? {
        get { defaults.data(forKey: Key.alertState) }
        set { defaults.set(newValue, forKey: Key.alertState) }
    }

    var touchBarConfiguration: TouchBarConfiguration {
        get { TouchBarConfiguration.decode(defaults.data(forKey: Key.buttons)) }
        set {
            guard newValue != touchBarConfiguration, let data = newValue.encoded() else { return }
            defaults.set(data, forKey: Key.buttons)
            NotificationCenter.default.post(name: Self.buttonsDidChange, object: self)
        }
    }

    var touchBarEnabled: Bool {
        get { defaults.object(forKey: Key.touchBarEnabled) as? Bool ?? true }
        set {
            guard newValue != touchBarEnabled else { return }
            defaults.set(newValue, forKey: Key.touchBarEnabled)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    var refreshPolicy: QuotaRefreshPolicy {
        get {
            let legacy = (defaults.object(forKey: Key.legacyRefreshInterval) as? NSNumber)?.doubleValue ?? 30
            return .decode(defaults.data(forKey: Key.refreshPolicy), legacyInterval: legacy)
        }
        set {
            guard newValue != refreshPolicy, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.refreshPolicy)
            NotificationCenter.default.post(name: Self.refreshDidChange, object: self)
        }
    }

    var hasAttemptedLoginSetup: Bool {
        get { defaults.bool(forKey: Key.loginSetupAttempted) }
        set { defaults.set(newValue, forKey: Key.loginSetupAttempted) }
    }
}
