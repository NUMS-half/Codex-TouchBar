import Foundation

enum UsageMonitoringDiagnostics {
    struct CheckFailure: Error { let message: String }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckFailure(message: message) }
    }
    static func point(_ remaining: Int, _ seconds: Double, kind: UsageWindowKind = .fiveHour,
                      reset: Double = 1_000, plan: String = "plus") -> UsageObservation {
        .init(kind: kind, time: Date(timeIntervalSince1970: seconds), remaining: remaining,
              duration: kind == .fiveHour ? 300 : 10_080, reset: Date(timeIntervalSince1970: reset), plan: plan)
    }
    static func run() -> Bool {
        do {
            try alerts(); try history(); try chart(); try QuotaExperienceDiagnostics.run()
            print("Usage monitoring self-test passed (alerts, history, chart data)")
            return true
        } catch {
            print("Usage monitoring self-test failed: \(error)")
            return false
        }
    }
    private static func configured() -> UsageAlertEngine {
        var engine = UsageAlertEngine()
        engine.configure(.init(fiveHourLow: true, weeklyLow: true, fiveHourRecovery: true, weeklyRecovery: true))
        return engine
    }
    static func alerts() throws {
        var engine = configured()
        try check(engine.consume([point(50, 0)]).isEmpty, "first sample establishes baseline")
        try check(engine.consume([point(20, 60)]).isEmpty, "low threshold is strictly below")
        try check(engine.consume([point(19, 90)]).first?.reason == .low(20), "default low crossing")
        try check(engine.consume([point(5, 120)]).isEmpty, "continuous low does not repeat")
        _ = engine.consume([point(20, 150)])
        _ = engine.consume([point(20, 180)])
        try check(engine.consume([point(19, 210)]).first?.reason == .low(20), "low rearms after confirmed return")
        _ = engine.consume([point(100, 240)])
        try check(engine.consume([point(100, 255)]).isEmpty, "recovery confirmation waits at least 30 seconds")
        engine = try JSONDecoder().decode(UsageAlertEngine.self, from: JSONEncoder().encode(engine))
        try check(engine.consume([point(100, 270)]).first?.reason == .recovered, "pending default recovery persists")
        try check(engine.consume([point(100, 300)]).isEmpty, "continuous recovered state deduplicates")
        _ = engine.consume([point(99, 330)])
        _ = engine.consume([point(100, 360)])
        try check(engine.consume([point(99, 390)]).isEmpty, "transient threshold crossing is not confirmed")
        _ = engine.consume([point(100, 420)])
        try check(engine.consume([point(100, 450)]).first?.reason == .recovered, "recovery rearmed below target")
        engine.configure(.init())
        try check(engine.consume([point(5, 480)]).isEmpty, "disabled does not notify")
        engine.configure(.init(fiveHourLow: true, fiveHourRecovery: true))
        try check(engine.consume([point(5, 510)]).isEmpty && engine.consume([point(4, 540)]).isEmpty, "reenable does not backfill existing low")
        engine.reset()
        try check(engine.consume([point(100, 570)]).isEmpty && engine.consume([point(100, 600)]).isEmpty, "already above recovery at baseline is not notified")

        let custom = UsageAlertOptions(fiveHourLow: true, weeklyLow: true, fiveHourRecovery: true, weeklyRecovery: true,
                                      fiveHourLowThreshold: 35, weeklyLowThreshold: 60,
                                      fiveHourRecoveryThreshold: 80, weeklyRecoveryThreshold: 90)
        engine.configure(custom)
        _ = engine.consume([point(50, 700), point(70, 700, kind: .weekly)])
        try check(engine.consume([point(35, 730)]).isEmpty, "custom low equality does not trigger")
        let low = engine.consume([point(34, 760), point(59, 760, kind: .weekly)])
        try check(low.count == 2 && low[0].reason == .low(35) && low[1].reason == .low(60), "window thresholds independent")
        try check(engine.consume([point(79, 790), point(89, 790, kind: .weekly)]).isEmpty, "large increase below target does not notify")
        _ = engine.consume([point(80, 820), point(90, 820, kind: .weekly)])
        let restored = engine.consume([point(81, 850), point(91, 850, kind: .weekly)])
        try check(restored.count == 2 && restored.allSatisfy { $0.reason == .recovered }, "custom threshold confirms small increase")
        let batch = UsageAlertBatch(events: restored, observations: [point(81, 850), point(91, 850, kind: .weekly)])
        try check(batch.body.contains("5H") && batch.body.contains("周"), "two recovery events merge")
        engine = try JSONDecoder().decode(UsageAlertEngine.self, from: JSONEncoder().encode(engine))
        try check(engine.consume([point(85, 880), point(95, 880, kind: .weekly)]).isEmpty, "restart keeps deduplication")
        var changed = custom; changed.fiveHourRecoveryThreshold = 85
        engine.configure(changed)
        try check(engine.consume([point(90, 910)]).isEmpty && engine.consume([point(90, 940)]).isEmpty, "threshold change establishes new baseline without retroactive alert")
        _ = engine.consume([point(84, 970)]); _ = engine.consume([point(85, 1_000)])
        try check(engine.consume([point(85, 2_801)]).isEmpty, "candidate expires after 30 minutes")
        _ = engine.consume([point(84, 2_830)]); _ = engine.consume([point(85, 2_860)])
        try check(engine.consume([point(100, 2_890, plan: "pro")]).isEmpty, "plan change cancels pending recovery")
        try check(engine.consume([]).isEmpty && engine.consume([point(100, 2_880, plan: "pro")]).isEmpty, "missing and out-of-order samples ignored")

        engine.configure(.init(fiveHourLow: true, fiveHourRecovery: true, fiveHourLowThreshold: 1, fiveHourRecoveryThreshold: 1))
        _ = engine.consume([point(1, 3_000)])
        try check(engine.consume([point(0, 3_030)]).first?.reason == .low(1), "minimum low threshold catches zero")
        _ = engine.consume([point(1, 3_060)])
        try check(engine.consume([point(1, 3_090)]).first?.reason == .recovered, "minimum recovery threshold")
        let limited = UsageAlertBatch(events: [.init(kind: .fiveHour, remaining: 100, reason: .recovered)],
                                     observations: [point(100, 3_120), point(0, 3_120, kind: .weekly)])
        try check(limited.body.contains("周 额度仍为 0%"), "other window still exhausted")

        let old = Data(#"{"fiveHourLow":true,"weeklyLow":false,"fiveHourRecovery":false,"weeklyRecovery":true}"#.utf8)
        let migrated = try JSONDecoder().decode(UsageAlertOptions.self, from: old)
        try check(migrated.fiveHourLow && migrated.weeklyRecovery && migrated.lowThreshold(.fiveHour) == 20 && migrated.recoveryThreshold(.weekly) == 100,
                  "old switches survive with new defaults")
        let invalid = Data(#"{"fiveHourLow":true,"fiveHourLowThreshold":0,"weeklyLowThreshold":101,"fiveHourRecoveryThreshold":"bad"}"#.utf8)
        let repaired = try JSONDecoder().decode(UsageAlertOptions.self, from: invalid)
        try check(repaired.fiveHourLow && repaired.lowThreshold(.fiveHour) == 20 && repaired.lowThreshold(.weekly) == 20 && repaired.recoveryThreshold(.fiveHour) == 100,
                  "invalid thresholds recover individually")
        try check(UsageAlertEngine().version == UsageAlertEngine.currentVersion, "new engine state version")
    }

    static func history() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        var db: UsageHistoryDatabase? = UsageHistoryDatabase(url: url)
        try db!.recovering {
            try db!.append([point(80, 120), point(60, 150)], now: Date(timeIntervalSince1970: 150))
            let points = try db!.read(.fiveHour, now: Date(timeIntervalSince1970: 150))
            try check(points.count == 1 && points[0].remaining == 60 && points[0].time.timeIntervalSince1970 == 150, "minute upsert retains latest")
        }
        db = nil
        db = UsageHistoryDatabase(url: url)
        try db!.recovering {
            try check(tryReadCount(db!, .fiveHour, 150) == 1, "reopen history")
            try db!.append([point(70, 180, kind: .weekly)], now: Date(timeIntervalSince1970: 180))
            try db!.pruneIfNeeded(now: Date(timeIntervalSince1970: 49 * 3_600))
            try check(tryReadCount(db!, .fiveHour, 49 * 3_600) == 0 && tryReadCount(db!, .weekly, 49 * 3_600) == 1, "independent retention")
            try db!.pruneIfNeeded(now: Date(timeIntervalSince1970: 11 * 86_400))
            try check(tryReadCount(db!, .weekly, 11 * 86_400) == 0, "weekly retention")
        }
        db = nil

        let retentionURL = root.appendingPathComponent("retention.sqlite")
        let boundary = 10_000.0
        do {
            let old = UsageHistoryDatabase(url: retentionURL)
            try old.recovering {
                try old.append([point(80, boundary - 60, kind: .weekly), point(70, boundary, kind: .weekly),
                                point(60, boundary + 86_400, kind: .weekly)], now: Date(timeIntervalSince1970: boundary + 86_400))
            }
        }
        let reopened = UsageHistoryDatabase(url: retentionURL)
        try reopened.recovering {
            let now = Date(timeIntervalSince1970: boundary + 10 * 86_400)
            try reopened.pruneIfNeeded(now: now)
            let kept = try reopened.read(.weekly, now: now)
            try check(kept.count == 2 && kept.first?.time.timeIntervalSince1970 == boundary,
                      "reopened history drops records older than ten days and keeps the exact boundary")
        }

        let brokenURL = root.appendingPathComponent("broken.sqlite")
        let damaged = Data("deliberately invalid sqlite fixture".utf8)
        try damaged.write(to: brokenURL)
        let broken = UsageHistoryDatabase(url: brokenURL)
        try broken.recovering { try broken.append([point(50, 120)], now: Date(timeIntervalSince1970: 120)) }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = files.first { $0.lastPathComponent.hasPrefix("broken.sqlite.damaged-") && !$0.path.hasSuffix("-wal") && !$0.path.hasSuffix("-shm") }
        try check(broken.notice != nil && backup != nil, "corruption backed up")
        if let backup { let data = try Data(contentsOf: backup); try check(data == damaged, "backup content retained") }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        do {
            let impossible = UsageHistoryDatabase(url: blocked.appendingPathComponent("history.sqlite"))
            try impossible.recovering { try impossible.clear() }
            throw CheckFailure(message: "storage failure must propagate")
        } catch is CheckFailure { throw CheckFailure(message: "storage failure must propagate") }
        catch { /* Expected filesystem error; no impact on quota model. */ }

        let fullURL = root.appendingPathComponent("full.sqlite")
        let full = UsageHistoryDatabase(url: fullURL)
        let now = Date(timeIntervalSince1970: 2_000_000)
        var samples: [UsageObservation] = []
        for kind in UsageWindowKind.allCases {
            for minute in 0..<Int(kind.historyDuration / 60) {
                samples.append(point(100 - (minute / 60) % 100, now.timeIntervalSince1970 - kind.historyDuration + Double(minute * 60 + 60), kind: kind))
            }
        }
        let start = Date()
        try full.recovering {
            try full.append(samples, now: now)
            try check(tryReadCount(full, .fiveHour, now.timeIntervalSince1970) == 2_880, "48 hour capacity")
            try check(tryReadCount(full, .weekly, now.timeIntervalSince1970) == 14_400, "10 day capacity")
        }
        let size = ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: fullURL.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        print("History capacity: 17280 samples, SQLite + sidecars \(size) bytes, fixture write/read \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        try full.recovering { try full.clear(); try check(tryReadCount(full, .weekly, now.timeIntervalSince1970) == 0, "clear both histories") }
    }
    private static func tryReadCount(_ database: UsageHistoryDatabase, _ kind: UsageWindowKind, _ now: Double) -> Int {
        (try? database.read(kind, now: Date(timeIntervalSince1970: now)).count) ?? -1
    }
    static func chart() throws {
        try check(UsageChartRange.fiveHourOptions == [.sixHours, .twelveHours]
                  && UsageChartRange.defaultRange(for: .fiveHour) == .sixHours,
                  "5H offers only six and twelve hours with a six-hour default")
        let samples = (0..<144).map { point(100 - $0 / 2, Double($0 * 300 + 60)) }
        for (range, count, interval) in [(UsageChartRange.sixHours, 36, 600.0), (.twelveHours, 48, 900.0)] {
            let bars = UsageChartBucket.make(samples, range: range,
                start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: range.duration))
            try check(range.bucketInterval == interval && bars.count == count
                      && bars.reduce(0) { $0 + $1.count } == Int(range.duration / 300),
                      "selected range preserves its visible records at the requested resolution")
        }
        for range in UsageChartRange.allCases {
            let records = [point(80, 1_060, kind: range.kind), point(20, 30_000, kind: range.kind)]
            let selected = UsageChartBucket.make(records, range: range,
                start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 1_000 + range.duration))
            try check(selected.reduce(0) { $0 + $1.count } == (range == .sixHours ? 1 : 2), "range filtering keeps only visible observed samples")
        }
        func gap(_ from: UsageObservation, _ to: UsageObservation) -> [UsageChartBucket] {
            UsageChartBucket.make([from, to], range: .twelveHours,
                start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))
        }
        let bars = UsageChartBucket.make([point(40, 1_100, reset: 5_000), point(80, 1_050, reset: 5_000),
            point(0, 1_075, reset: 5_000), point(20, 3_150, reset: 5_000), point(90, 800),
            point(50, 3_750), point(95, 1_100, kind: .weekly)], range: .twelveHours,
            start: Date(timeIntervalSince1970: 900), end: Date(timeIntervalSince1970: 3_600))
        try check(bars.count == 3 && bars[0].remaining == 40 && bars[0].count == 3,
                  "bar height is last query, not a total, average or array order")
        try check(bars[0].minimum == 0 && bars[0].maximum == 80, "observed extrema survive aggregation")
        try check(bars[1].start == Date(timeIntervalSince1970: 1_800) && bars[1].remaining == 29
                  && bars[1].estimateKind == .consumption && bars[1].count == 0,
                  "same-cycle declining gap can be interpolated")
        try check(bars.reduce(0) { $0 + $1.count } == 4, "estimated columns never become observed records")
        let before = point(20, 1_100, reset: 1_500)
        let after = point(100, 4_050, reset: 7_500)
        let resetGap = gap(before, after)
        let held = resetGap.filter(\.isEstimated)
        try check(held.count == 2 && held.allSatisfy { $0.remaining == 20 && $0.estimateKind == .lastKnown }
                  && resetGap.last?.remaining == 100, "refresh is a step, never an upward ramp")
        let partial = gap(before, point(75, 4_050, reset: 7_500))
        try check(partial.allSatisfy { $0.remaining == 20 || $0.remaining == 75 }, "unobserved full quota is never fabricated")
        let rising = gap(point(40, 1_100, reset: 7_500), point(45, 4_050, reset: 7_500))
        try check(rising.filter(\.isEstimated).allSatisfy { $0.remaining == 40 }, "small rises do not produce upward interpolation")
        let changed = gap(before, point(10, 4_050, reset: 7_500, plan: "pro"))
        try check(changed.filter(\.isEstimated).allSatisfy { $0.remaining == 20 }, "scope changes are not consumption")
        let expired = gap(point(40, 1_100, reset: 1_500), point(10, 4_050, reset: 1_500))
        try check(expired.filter(\.isEstimated).allSatisfy { $0.estimateKind == .lastKnown }, "expired cycle is not interpolated")
        var unknown = before; unknown.reset = nil
        try check(gap(unknown, after).filter(\.isEstimated).allSatisfy { $0.estimateKind == .lastKnown }, "unknown reset is conservative")
        try check(resetGap.first?.start == Date(timeIntervalSince1970: 900)
                  && resetGap.last?.end == Date(timeIntervalSince1970: 4_500), "no leading or trailing invented history")
        let zero = gap(point(0, 1_100), point(0, 1_100))
        try check(zero.count == 1 && zero[0].remaining == 0 && !zero[0].isEstimated, "measured zero is not missing")
        let edge = UsageChartBucket.make([point(60, 3_600)], range: .twelveHours,
            start: Date(timeIntervalSince1970: 900), end: Date(timeIntervalSince1970: 3_600))
        try check(edge.count == 1, "query at right range boundary is retained")
        let full = (0..<14_400).map { point($0 == 100 ? 0 : ($0 == 101 ? 100 : 50), Double($0 * 60), kind: .weekly) }
        let compact = UsageChartBucket.make(full, range: .tenDays, start: full[0].time, end: full.last!.time)
        try check(UsageChartRange.tenDays.duration == 10 * 86_400 && UsageChartRange.tenDays.bucketInterval == 21_600
                  && compact.count == 40 && compact.reduce(0) { $0 + $1.count } == 14_400
                  && compact.contains { $0.minimum == 0 && $0.maximum == 100 }, "ten-day weekly view has forty six-hour bars")
    }
}
