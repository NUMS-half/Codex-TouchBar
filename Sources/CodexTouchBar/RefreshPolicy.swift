import Foundation

/// Only these events can initiate a quota query. UI redraws and history reads cannot.
enum QuotaRefreshTrigger: String, CaseIterable, Codable {
    case launch, menuOpen, foreground, wake, foregroundTimer, backgroundTimer, touchBar, manual

    var title: String {
        switch self {
        case .launch: return "启动工具时刷新"
        case .menuOpen: return "打开菜单栏面板时刷新"
        case .foreground: return "ChatGPT切到前台时刷新"
        case .wake: return "电脑从睡眠唤醒时刷新"
        case .touchBar: return "允许Touch Bar刷新按钮查询"
        case .foregroundTimer: return "ChatGPT前台定时刷新"
        case .backgroundTimer: return "ChatGPT后台定时刷新"
        case .manual: return "手动刷新"
        }
    }
}

struct QuotaRefreshPolicy: Codable, Equatable {
    static let intervals: [TimeInterval] = [30, 60, 120, 300, 600]

    static func intervalTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 30: return "30 秒"
        case 60: return "1 分钟"
        default: return "\(Int(interval / 60)) 分钟"
        }
    }

    var version = 1
    private var enabled: [String: Bool] = [:]
    var foregroundInterval: TimeInterval = 30
    var backgroundInterval: TimeInterval = 300

    func allows(_ trigger: QuotaRefreshTrigger) -> Bool {
        trigger == .manual || enabled[trigger.rawValue] ?? true
    }
    mutating func setEnabled(_ value: Bool, for trigger: QuotaRefreshTrigger) {
        guard trigger != .manual else { return }
        enabled[trigger.rawValue] = value
    }
    func timerInterval(isForeground: Bool) -> TimeInterval? {
        guard allows(isForeground ? .foregroundTimer : .backgroundTimer) else { return nil }
        return isForeground ? foregroundInterval : backgroundInterval
    }
    @discardableResult
    func perform(_ trigger: QuotaRefreshTrigger, operation: () -> Void) -> Bool {
        guard allows(trigger) else { return false }
        operation()
        return true
    }
    static func decode(_ data: Data?, legacyInterval: TimeInterval) -> Self {
        var fallback = Self()
        if Self.intervals.contains(legacyInterval) { fallback.foregroundInterval = legacyInterval }
        guard let data, var policy = try? JSONDecoder().decode(Self.self, from: data), policy.version == 1 else { return fallback }
        if !Self.intervals.contains(policy.foregroundInterval) { policy.foregroundInterval = fallback.foregroundInterval }
        if !Self.intervals.contains(policy.backgroundInterval) { policy.backgroundInterval = 300 }
        return policy
    }
}
