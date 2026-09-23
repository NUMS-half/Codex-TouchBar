import Foundation

enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour
    case weekly

    var title: String {
        switch self {
        case .fiveHour: return "5H"
        case .weekly: return "周"
        }
    }

    var accessibleTitle: String {
        switch self {
        case .fiveHour: return "5 小时额度"
        case .weekly: return "每周额度"
        }
    }
}

struct UsageWindow: Codable, Sendable, Equatable {
    let kind: UsageWindowKind
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

/// The complete, non-sensitive state needed to render all surfaces.
struct UsageSnapshot: Codable, Sendable, Equatable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let planType: String?
    let limitName: String?
    let creditBalance: String?
    let unlimitedCredits: Bool
    let availableResetCredits: Int
    let fetchedAt: Date
    let earliestAvailableResetExpiry: Date?

    init(
        fiveHour: UsageWindow?,
        weekly: UsageWindow?,
        planType: String?,
        limitName: String?,
        creditBalance: String?,
        unlimitedCredits: Bool,
        availableResetCredits: Int,
        fetchedAt: Date,
        earliestAvailableResetExpiry: Date? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
        self.limitName = limitName
        self.creditBalance = creditBalance
        self.unlimitedCredits = unlimitedCredits
        self.availableResetCredits = availableResetCredits
        self.fetchedAt = fetchedAt
        self.earliestAvailableResetExpiry = earliestAvailableResetExpiry
    }
}

enum SnapshotFreshness: Sendable, Equatable {
    case live
    case cached
    case stale(String)

    var isStale: Bool {
        if case .live = self { return false }
        return true
    }
}

enum UsageServiceError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case rpc(String)
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex 可执行文件"
        case .launchFailed(let detail):
            return "启动 Codex 额度服务失败：\(detail)"
        case .timedOut:
            return "读取额度超时"
        case .invalidResponse:
            return "Codex 返回的额度数据无法识别"
        case .rpc(let message):
            let lower = message.lowercased()
            if lower.contains("authentication") || lower.contains("not signed in") || lower.contains("not logged") {
                return "未登录 Codex，请先打开 Codex 完成登录"
            }
            return message
        case .processExited(let detail):
            return "Codex 额度服务异常退出：\(detail)"
        }
    }
}

protocol UsageProvider: Sendable {
    func fetch(includeResetCreditDetails: Bool) async throws -> UsageSnapshot
}

/// Converts the app-server JSON response into stable UI values. It deliberately
/// identifies windows by duration instead of historical primary/secondary positions.
enum UsageSnapshotParser {
    private static let fiveHourRange = 240...360
    private static let weeklyRange = 8_640...11_520

    static func parse(data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageServiceError.invalidResponse
        }
        return try parse(result: root, now: now)
    }

    static func parse(result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        guard let limits = preferredLimits(from: result) else {
            throw UsageServiceError.invalidResponse
        }

        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        for key in ["primary", "secondary"] {
            guard let raw = limits[key] as? [String: Any], let window = parseWindow(raw) else { continue }
            switch window.kind {
            case .fiveHour: fiveHour = window
            case .weekly: weekly = window
            }
        }

        let credits = limits["credits"] as? [String: Any]
        let resetSummary = result["rateLimitResetCredits"] as? [String: Any]
        let earliestResetExpiry = (resetSummary?["credits"] as? [[String: Any]])?
            .filter {
                ($0["status"] as? String) == "available"
                    && ($0["resetType"] as? String) == "codexRateLimits"
            }
            .compactMap { double($0["expiresAt"]) }
            .map(Date.init(timeIntervalSince1970:))
            .filter { $0 > now }
            .min()
        return UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            planType: limits["planType"] as? String,
            limitName: limits["limitName"] as? String,
            creditBalance: credits?["balance"] as? String,
            unlimitedCredits: bool(credits?["unlimited"]) ?? false,
            availableResetCredits: int(resetSummary?["availableCount"]) ?? 0,
            fetchedAt: now,
            earliestAvailableResetExpiry: earliestResetExpiry
        )
    }

    private static func preferredLimits(from result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(_ raw: [String: Any]) -> UsageWindow? {
        guard let used = int(raw["usedPercent"]),
              let kind = classify(int(raw["windowDurationMins"])) else { return nil }
        let duration = int(raw["windowDurationMins"])
        let reset = double(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        return UsageWindow(
            kind: kind,
            usedPercent: max(0, min(100, used)),
            durationMinutes: duration,
            resetsAt: reset
        )
    }

    private static func classify(_ duration: Int?) -> UsageWindowKind? {
        guard let duration else { return nil }
        if fiveHourRange.contains(duration) { return .fiveHour }
        if weeklyRange.contains(duration) { return .weekly }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
    }
}
