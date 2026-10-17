import Foundation

/// Describes observations, never extrapolates future quota or bridges a sampling break.
struct UsageRecentChange: Equatable, Sendable {
    let kind: UsageWindowKind
    let duration: TimeInterval
    let decrease: Int

    static func lookback(_ kind: UsageWindowKind) -> TimeInterval {
        kind == .fiveHour ? 1_800 : 86_400
    }

    static func summarize(_ points: [UsageObservation], current: UsageObservation) -> Self? {
        guard let reset = current.reset, reset > current.time else { return nil }
        let cutoff = current.time.addingTimeInterval(-lookback(current.kind))
        // SQLite round trips can slightly change Date precision. Prefer its latest
        // matching row so persisted breaks within that minute remain authoritative.
        let latest = points.last { $0.kind == current.kind && abs($0.time.timeIntervalSince(current.time)) < 0.001 && $0.remaining == current.remaining }
        var first = latest ?? current
        let candidates = points.filter { $0.kind == current.kind && $0.time >= cutoff && $0.time < first.time }
            .sorted { $0.time < $1.time }
        for previous in candidates.reversed() {
            guard !first.discontinuity, first.continuesConsumption(from: previous) else { break }
            first = previous
            if previous.time <= cutoff { break }
        }
        let duration = current.time.timeIntervalSince(first.time)
        guard duration >= (current.kind == .fiveHour ? 900 : 3_600) else { return nil }
        return Self(kind: current.kind, duration: duration, decrease: first.remaining - current.remaining)
    }

    var text: String {
        let span: String
        switch kind {
        case .fiveHour:
            span = "\(Int(duration / 60))分钟"
        case .weekly:
            let hours = (duration / 3_600 * 10).rounded() / 10
            span = hours.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(hours))小时"
                : String(format: "%.1f小时", locale: Locale(identifier: "zh_CN"), hours)
        }
        return decrease == 0 ? "近\(span)观测无变化" : "近\(span)观测下降\(decrease)%"
    }
}
