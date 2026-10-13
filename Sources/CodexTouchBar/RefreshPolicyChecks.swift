import Foundation

enum RefreshPolicyChecks {
    private final class Notifications: @unchecked Sendable {
        var general = 0
        var refresh = 0
    }

    static func run() -> Bool {
        let suite = "CodexTouchBar.RefreshPolicy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(120, forKey: "refreshIntervalSeconds")
        let preferences = Preferences(defaults: defaults)
        let counts = Notifications()
        let center = NotificationCenter.default
        let generalToken = center.addObserver(forName: Preferences.didChange, object: nil, queue: nil) { _ in counts.general += 1 }
        let refreshToken = center.addObserver(forName: Preferences.refreshDidChange, object: nil, queue: nil) { _ in counts.refresh += 1 }
        defer { center.removeObserver(generalToken); center.removeObserver(refreshToken) }
        preferences.touchBarEnabled = true
        guard counts.general == 0 else { return false }
        preferences.touchBarEnabled = false
        preferences.touchBarEnabled = false
        guard counts.general == 1, counts.refresh == 0 else { return false }
        var policy = preferences.refreshPolicy
        guard policy.foregroundInterval == 120, policy.backgroundInterval == 300,
              QuotaRefreshTrigger.allCases.allSatisfy({ policy.allows($0) }) else { return false }
        for trigger in QuotaRefreshTrigger.allCases where trigger != .manual {
            policy.setEnabled(false, for: trigger)
            var calls = 0
            guard !policy.perform(trigger, operation: { calls += 1 }), calls == 0 else { return false }
        }
        var manualCalls = 0
        guard policy.perform(.manual, operation: { manualCalls += 1 }), manualCalls == 1,
              policy.timerInterval(isForeground: true) == nil, policy.timerInterval(isForeground: false) == nil else { return false }
        policy.backgroundInterval = 600
        preferences.refreshPolicy = policy
        preferences.refreshPolicy = policy
        guard counts.refresh == 1, counts.general == 1 else { return false }
        guard Preferences(defaults: defaults).refreshPolicy == policy else { return false }
        policy.setEnabled(true, for: .foregroundTimer)
        guard policy.timerInterval(isForeground: true) == 120, policy.timerInterval(isForeground: false) == nil else { return false }
        preferences.refreshPolicy = policy
        var changedInterval = preferences.refreshPolicy
        changedInterval.foregroundInterval = 60
        preferences.refreshPolicy = changedInterval
        guard preferences.refreshPolicy.foregroundInterval == 60, !preferences.refreshPolicy.allows(.wake) else { return false }
        var invalid = policy; invalid.foregroundInterval = -1; invalid.backgroundInterval = 0
        let sanitized = QuotaRefreshPolicy.decode(try? JSONEncoder().encode(invalid), legacyInterval: 120)
        guard sanitized.foregroundInterval == 120, sanitized.backgroundInterval == 300,
              QuotaRefreshPolicy.decode(Data("invalid".utf8), legacyInterval: 60).foregroundInterval == 60 else { return false }
        invalid.version = 99
        guard QuotaRefreshPolicy.decode(try? JSONEncoder().encode(invalid), legacyInterval: 30) == .init() else { return false }
        print("Refresh policy self-test passed (seven gates, manual override, timers, persistence, migration, invalid records)")
        return true
    }
}
