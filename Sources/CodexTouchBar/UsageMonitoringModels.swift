import Foundation

extension UsageWindowKind {
    var historyDuration: TimeInterval { self == .fiveHour ? 48 * 3_600 : 10 * 86_400 }
}

struct UsageObservation: Codable, Equatable, Sendable {
    var kind: UsageWindowKind
    var time: Date
    var remaining: Int
    var duration: Int?
    var reset: Date?
    var plan: String?
    var limitName: String?
    var rise = false
    var discontinuity = false

    static func from(_ snapshot: UsageSnapshot) -> [Self] {
        [snapshot.fiveHour, snapshot.weekly].compactMap { window in
            guard let window else { return nil }
            return Self(kind: window.kind, time: snapshot.fetchedAt, remaining: window.remainingPercent,
                        duration: window.durationMinutes, reset: window.resetsAt,
                        plan: snapshot.planType, limitName: snapshot.limitName)
        }
    }

    func changedScope(from previous: Self) -> Bool {
        func changed<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
            if let a, let b { return a != b }; return false
        }
        return changed(duration, previous.duration) || changed(plan, previous.plan)
            || changed(limitName, previous.limitName)
    }

    /// Also persisted through minute coalescing, so an intervening rise cannot disappear.
    func continuesConsumption(from previous: Self) -> Bool {
        let sameReset: Bool
        switch (reset, previous.reset) {
        case (nil, nil): sameReset = true
        case let (current?, old?): sameReset = abs(current.timeIntervalSince(old)) < 1
        default: sameReset = false
        }
        return kind == previous.kind && time > previous.time && time.timeIntervalSince(previous.time) <= 900
            && remaining <= previous.remaining && duration == previous.duration
            && plan == previous.plan && limitName == previous.limitName && sameReset
    }

    /// Chart annotation thresholds, separate from user-configured alert targets.
    func recoveryGain(from previous: Self) -> Int? {
        guard !changedScope(from: previous), remaining > 20 else { return nil }
        if remaining - previous.remaining >= 20 { return 20 }
        if let old = previous.reset, let new = reset, time >= old,
           new.timeIntervalSince(old) > 60, remaining - previous.remaining >= 5 { return 5 }
        return nil
    }
}

struct UsageAlertOptions: Codable, Equatable, Sendable {
    var fiveHourLow = false
    var weeklyLow = false
    var fiveHourRecovery = false
    var weeklyRecovery = false
    var fiveHourLowThreshold = 20
    var weeklyLowThreshold = 20
    var fiveHourRecoveryThreshold = 100
    var weeklyRecoveryThreshold = 100
    var resetExpiry = false
    func low(_ kind: UsageWindowKind) -> Bool { kind == .fiveHour ? fiveHourLow : weeklyLow }
    func recovery(_ kind: UsageWindowKind) -> Bool { kind == .fiveHour ? fiveHourRecovery : weeklyRecovery }
    func lowThreshold(_ kind: UsageWindowKind) -> Int {
        let value = kind == .fiveHour ? fiveHourLowThreshold : weeklyLowThreshold
        return (1...100).contains(value) ? value : 20
    }
    func recoveryThreshold(_ kind: UsageWindowKind) -> Int {
        let value = kind == .fiveHour ? fiveHourRecoveryThreshold : weeklyRecoveryThreshold
        return (1...100).contains(value) ? value : 100
    }
    var anyEnabled: Bool { fiveHourLow || weeklyLow || fiveHourRecovery || weeklyRecovery || resetExpiry }
    enum CodingKeys: String, CodingKey {
        case fiveHourLow, weeklyLow, fiveHourRecovery, weeklyRecovery
        case fiveHourLowThreshold, weeklyLowThreshold, fiveHourRecoveryThreshold, weeklyRecoveryThreshold
        case resetExpiry
    }
}

extension UsageAlertOptions {
    // Decode old four-switch preferences without discarding the user's choices.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHourLow = try container.decodeIfPresent(Bool.self, forKey: .fiveHourLow) ?? false
        weeklyLow = try container.decodeIfPresent(Bool.self, forKey: .weeklyLow) ?? false
        fiveHourRecovery = try container.decodeIfPresent(Bool.self, forKey: .fiveHourRecovery) ?? false
        weeklyRecovery = try container.decodeIfPresent(Bool.self, forKey: .weeklyRecovery) ?? false
        resetExpiry = try container.decodeIfPresent(Bool.self, forKey: .resetExpiry) ?? false
        func threshold(_ key: CodingKeys, default fallback: Int) -> Int {
            guard let value = try? container.decode(Int.self, forKey: key), (1...100).contains(value) else { return fallback }
            return value
        }
        fiveHourLowThreshold = threshold(.fiveHourLowThreshold, default: 20)
        weeklyLowThreshold = threshold(.weeklyLowThreshold, default: 20)
        fiveHourRecoveryThreshold = threshold(.fiveHourRecoveryThreshold, default: 100)
        weeklyRecoveryThreshold = threshold(.weeklyRecoveryThreshold, default: 100)
    }
}

struct UsageAlertEvent: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case low(Int), recovered, resetExpiring(Date) }
    let kind: UsageWindowKind
    let remaining: Int
    let reason: Reason
    var text: String {
        switch reason {
        case .low(let threshold): return "\(kind.title) 额度低于 \(threshold)%，当前剩余 \(remaining)%"
        case .recovered: return "\(kind.title) 额度已恢复至 \(remaining)%"
        case .resetExpiring(let date): return "最近一次可用重置机会将在\(formatResetDate(date))到期，请及时查看。"
        }
    }
}

struct UsageAlertBatch: Sendable {
    let events: [UsageAlertEvent]
    let observations: [UsageObservation]
    var selectedKind: UsageWindowKind { events.first?.kind ?? .fiveHour }
    var body: String {
        var lines = events.map(\.text)
        if events.contains(where: { $0.reason == .recovered }) {
            for point in observations where point.remaining == 0 && !events.contains(where: { $0.kind == point.kind }) {
                lines.append("\(point.kind.title) 额度仍为 0%")
            }
        }
        return lines.joined(separator: "；")
    }
}

/// Pure state machine. Persisting this value preserves deduplication across launches.
struct UsageAlertEngine: Codable {
    static let currentVersion = 2
    struct Pending: Codable { var started: Date }
    struct WindowState: Codable {
        var previous: UsageObservation?
        var lowNotified = false
        var lowRearmStarted: Date?
        var recoveryNotified = false
        var pending: Pending?
    }
    var version = Self.currentVersion
    private(set) var options = UsageAlertOptions()
    private var states: [String: WindowState] = [:]

    mutating func configure(_ new: UsageAlertOptions) {
        for kind in UsageWindowKind.allCases where options.low(kind) != new.low(kind)
            || options.recovery(kind) != new.recovery(kind)
            || options.lowThreshold(kind) != new.lowThreshold(kind)
            || options.recoveryThreshold(kind) != new.recoveryThreshold(kind) {
            states[kind.rawValue] = nil
        }
        options = new
    }

    mutating func reset() { states.removeAll() }

    mutating func consume(_ points: [UsageObservation]) -> [UsageAlertEvent] {
        var events: [UsageAlertEvent] = []
        for point in points {
            let kind = point.kind
            guard options.low(kind) || options.recovery(kind) else { continue }
            var state = states[kind.rawValue] ?? WindowState()
            if let previous = state.previous, point.time <= previous.time { continue }
            defer { state.previous = point; states[kind.rawValue] = state }
            guard let previous = state.previous else { continue }
            guard !point.changedScope(from: previous),
                  point.time.timeIntervalSince(previous.time) <= kind.historyDuration else {
                state = WindowState(); continue
            }
            let low = options.lowThreshold(kind)
            let recovery = options.recoveryThreshold(kind)

            // Rearm low alerts only after the balance stays out of the low
            // zone for a second successful observation at least 30 seconds later.
            if state.lowNotified && point.remaining >= low {
                if let start = state.lowRearmStarted, point.time.timeIntervalSince(start) >= 30 {
                    state.lowNotified = false; state.lowRearmStarted = nil
                } else if state.lowRearmStarted == nil { state.lowRearmStarted = point.time }
            } else { state.lowRearmStarted = nil }
            if options.low(kind), !state.lowNotified, previous.remaining >= low, point.remaining < low {
                state.lowNotified = true
                events.append(.init(kind: kind, remaining: point.remaining, reason: .low(low)))
            }

            if point.remaining < recovery {
                state.pending = nil; state.recoveryNotified = false
            } else if options.recovery(kind) {
                if let pending = state.pending {
                    let age = point.time.timeIntervalSince(pending.started)
                    if age > 1_800 { state.pending = nil }
                    else if age >= 30 {
                        state.pending = nil; state.recoveryNotified = true
                        events.append(.init(kind: kind, remaining: point.remaining, reason: .recovered))
                    }
                }
                if !state.recoveryNotified && state.pending == nil, previous.remaining < recovery {
                    state.pending = Pending(started: point.time)
                }
            }
        }
        return events
    }
}
