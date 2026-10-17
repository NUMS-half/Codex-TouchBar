import Foundation

/// Display-only interpolation never enters observations, history or alert calculations.
struct UsageChartBucket: Equatable {
    enum EstimateKind: Equatable { case consumption, lastKnown }
    let start: Date
    let end: Date
    let last: UsageObservation
    let first: UsageObservation
    let minimum: Int
    let maximum: Int
    let count: Int
    var estimatedAt: Date? = nil
    var estimate: Int? = nil
    var nextObservation: UsageObservation? = nil
    var estimateKind: EstimateKind? = nil
    var remaining: Int { estimate ?? last.remaining }
    var isEstimated: Bool { estimate != nil }

    private static func canEstimateConsumption(from previous: UsageObservation, to next: UsageObservation) -> Bool {
        guard !next.rise, next.remaining <= previous.remaining,
              previous.duration == next.duration, previous.plan == next.plan, previous.limitName == next.limitName,
              let oldReset = previous.reset, let newReset = next.reset else { return false }
        return abs(newReset.timeIntervalSince(oldReset)) < 1 && next.time < oldReset
    }

    static func make(_ points: [UsageObservation], range: UsageChartRange, start: Date, end: Date) -> [Self] {
        let interval = range.bucketInterval
        let visible = points.filter { $0.kind == range.kind && $0.time >= start && $0.time <= end }
        let groups = Dictionary(grouping: visible) { Int(floor($0.time.timeIntervalSince1970 / interval)) }
        let observed: [Self] = groups.keys.sorted().compactMap { key in
            guard let samples = groups[key], let last = samples.max(by: { $0.time < $1.time }),
                  let first = samples.min(by: { $0.time < $1.time }),
                  let minimum = samples.map(\.remaining).min(), let maximum = samples.map(\.remaining).max() else { return nil }
            let beginning = Date(timeIntervalSince1970: Double(key) * interval)
            return Self(start: beginning, end: beginning.addingTimeInterval(interval), last: last, first: first,
                        minimum: minimum, maximum: maximum, count: samples.count)
        }
        var result: [Self] = []
        for bucket in observed {
            if let previous = result.last {
                let consumption = canEstimateConsumption(from: previous.last, to: bucket.first)
                var missingStart = previous.end
                while missingStart < bucket.start {
                    let at = missingStart.addingTimeInterval(interval / 2)
                    let span = bucket.first.time.timeIntervalSince(previous.last.time)
                    let fraction = span > 0 ? max(0, min(1, at.timeIntervalSince(previous.last.time) / span)) : 0
                    // Across a refresh the time of the jump is unobserved. Hold the
                    // last reading until the next real sample; never draw an upward ramp.
                    let value = consumption
                        ? Int((Double(previous.last.remaining) + Double(bucket.first.remaining - previous.last.remaining) * fraction).rounded())
                        : previous.last.remaining
                    result.append(Self(start: missingStart, end: missingStart.addingTimeInterval(interval),
                        last: previous.last, first: previous.last, minimum: value, maximum: value, count: 0,
                        estimatedAt: at, estimate: value, nextObservation: bucket.first,
                        estimateKind: consumption ? .consumption : .lastKnown))
                    missingStart = missingStart.addingTimeInterval(interval)
                }
            }
            result.append(bucket)
        }
        return result
    }
}
