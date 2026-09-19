import Foundation

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("CodexTouchBar.PrefsDidChange")

    private let defaults = UserDefaults.standard
    private let touchBarEnabledKey = "touchBarEnabled"
    private let loginSetupAttemptedKey = "loginSetupAttempted"

    var touchBarEnabled: Bool {
        get { defaults.object(forKey: touchBarEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: touchBarEnabledKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    var hasAttemptedLoginSetup: Bool {
        get { defaults.bool(forKey: loginSetupAttemptedKey) }
        set { defaults.set(newValue, forKey: loginSetupAttemptedKey) }
    }
}
