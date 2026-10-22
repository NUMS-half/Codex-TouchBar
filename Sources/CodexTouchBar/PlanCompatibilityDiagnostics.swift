import Foundation

/// Synthetic protocol checks also execute on systems where XCTest only builds.
enum PlanCompatibilityDiagnostics {
    static func run() -> Bool {
        do {
            try parsing()
            try namesAndRequests()
            try cacheCompatibility()
            try windowTransitions()
            print("Plan compatibility self-test passed (server windows, family names, unknown resets, cache, alert baselines)")
            return true
        } catch {
            print("Plan compatibility self-test failed: \(error)")
            return false
        }
    }

    static func snapshot(plan: String = "pro", five: Int? = 80, weekly: Int? = 60,
                         time: Date = Date(timeIntervalSince1970: 100_000),
                         count: Int? = nil, expiry: Date? = nil) -> UsageSnapshot {
        .init(fiveHour: five.map { .init(kind: .fiveHour, usedPercent: 100 - $0, durationMinutes: 300,
                                       resetsAt: time.addingTimeInterval(3_600)) },
              weekly: weekly.map { .init(kind: .weekly, usedPercent: 100 - $0, durationMinutes: 10_080,
                                         resetsAt: time.addingTimeInterval(86_400)) },
              planType: plan, limitName: nil, creditBalance: nil, unlimitedCredits: false,
              availableResetCredits: count, fetchedAt: time, earliestAvailableResetExpiry: expiry)
    }

    static func parsing() throws {
        let check = UsageMonitoringDiagnostics.check
        let plans = ["free", "go", "plus", "pro", "prolite", "promax", "pro x5", "prox20", "future-plan"]
        for plan in plans {
            let result: [String: Any] = ["rateLimits": [
                "planType": plan,
                "primary": ["usedPercent": 40, "windowDurationMins": 10_080],
                "secondary": ["usedPercent": 20, "windowDurationMins": 300],
            ]]
            let value = try UsageSnapshotParser.parse(result: result)
            try check(value.fiveHour?.remainingPercent == 80 && value.weekly?.remainingPercent == 60
                      && value.planType == plan, "all plan types preserve raw scope and use duration, not position or name")
        }
        for duration in [15, 60, 240, 299, 301, 360, 1_440, 8_640, 10_079, 10_081, 11_520] {
            let value = try UsageSnapshotParser.parse(result: ["rateLimits": [
                "primary": ["usedPercent": 25, "windowDurationMins": duration],
            ]])
            try check(value.fiveHour == nil && value.weekly == nil, "nonstandard durations never masquerade as supported windows")
        }
        for window in [["usedPercent": 25], ["usedPercent": 25, "windowDurationMins": NSNull()]] as [[String: Any]] {
            let value = try UsageSnapshotParser.parse(result: ["rateLimits": ["primary": window]])
            try check(value.fiveHour == nil && value.weekly == nil, "missing and null durations are not inferred")
        }
        let empty = try UsageSnapshotParser.parse(result: ["rateLimits": [:]])
        try check(empty.fiveHour == nil && empty.weekly == nil && empty.availableResetCredits == nil,
                  "empty successful snapshot has no windows and unknown reset count")
        for summary: Any in [NSNull(), [:], ["availableCount": NSNull()], ["availableCount": -1]] {
            let value = try UsageSnapshotParser.parse(result: ["rateLimits": [:], "rateLimitResetCredits": summary])
            try check(value.availableResetCredits == nil, "unavailable or invalid reset count stays unknown")
        }
        for count in [0, 2] {
            let value = try UsageSnapshotParser.parse(result: ["rateLimits": [:], "rateLimitResetCredits": ["availableCount": count]])
            try check(value.availableResetCredits == count, "explicit zero and positive reset counts stay known")
        }
        var reminders = UsageReminderEngine()
        reminders.configure(expiryEnabled: true)
        let now = Date(timeIntervalSince1970: 100_000)
        for count: Int? in [nil, 0, 1] {
            let events = reminders.consume(snapshot(time: now, count: count, expiry: now.addingTimeInterval(3_600)), now: now)
            try check(events.isEmpty == (count != 1), "expiry reminders require a confirmed positive count")
        }
    }

    static func namesAndRequests() throws {
        let check = UsageMonitoringDiagnostics.check
        for (raw, expected) in [(" free ", "Free"), ("\tGo\n", "Go"), ("PLUS", "Plus"),
                                ("pro", "Pro"), ("ProLite", "Pro"), ("promax", "Pro"),
                                (" pro   x5 ", "Pro"), ("pro\tx20", "Pro"), ("prox5", "Pro"), ("PROX20", "Pro"),
                                (" Future Plan ", "Future Plan"), ("pro-next", "pro-next")] {
            try check(displayPlanName(raw) == expected, "known families normalize; unknown names retain readable raw text")
        }
        for explicit in [false, true] {
            for visible in [false, true] {
                for expiry in [false, true] {
                    let details = QuotaRefreshPolicy.includesResetCreditDetails(explicit: explicit, panelVisible: visible,
                                                                              expiryReminderEnabled: expiry)
                    try check(details == ([explicit, visible, expiry].contains(true)), "all detail request combinations")
                }
            }
        }
    }

    static func cacheCompatibility() throws {
        let check = UsageMonitoringDiagnostics.check
        let now = Date(timeIntervalSince1970: 100_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json")
        let cache = UsageCache(fileURL: file, now: { now })
        cache.save(snapshot(time: now))
        try check(cache.loadIfFresh()?.availableResetCredits == nil, "unknown reset count survives a cache round trip")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(time: now))) as! [String: Any]
        for count in [0, 2] {
            legacy["availableResetCredits"] = count
            try JSONSerialization.data(withJSONObject: legacy).write(to: file)
            try check(cache.loadIfFresh()?.availableResetCredits == count, "legacy integer counts remain readable")
        }
        legacy.removeValue(forKey: "availableResetCredits")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        try check(cache.loadIfFresh()?.availableResetCredits == nil, "missing cache count decodes as unknown")
    }

    static func windowTransitions() throws {
        let check = UsageMonitoringDiagnostics.check
        var engine = UsageAlertEngine()
        engine.configure(.init(fiveHourLow: true, weeklyLow: true, fiveHourRecovery: true, weeklyRecovery: true))
        func consume(_ value: UsageSnapshot) -> [UsageAlertEvent] {
            let points = UsageObservation.from(value)
            engine.resetMissingWindows(in: points)
            return engine.consume(points)
        }
        let now = Date(timeIntervalSince1970: 100_000)
        try check(consume(snapshot(time: now)).isEmpty, "first complete snapshot establishes baseline")
        try check(consume(snapshot(five: nil, weekly: 50, time: now.addingTimeInterval(60))).isEmpty,
                  "weekly-only success removes the five-hour baseline")
        try check(consume(snapshot(five: 5, weekly: 10, time: now.addingTimeInterval(120))).map(\.kind) == [.weekly],
                  "returning five-hour low is baseline only; continuing weekly low still alerts")
        _ = consume(snapshot(five: 100, weekly: 10, time: now.addingTimeInterval(180)))
        _ = consume(snapshot(five: nil, weekly: nil, time: now.addingTimeInterval(200)))
        try check(consume(snapshot(five: 100, weekly: 100, time: now.addingTimeInterval(240))).isEmpty,
                  "empty success cancels pending recoveries before windows return")
        try check(consume(snapshot(five: 100, weekly: 100, time: now.addingTimeInterval(300))).isEmpty,
                  "returned high baseline cannot confirm an old recovery candidate")
        _ = consume(snapshot(plan: "prolite", five: 50, weekly: 50, time: now.addingTimeInterval(360)))
        try check(consume(snapshot(plan: "promax", five: 5, weekly: 5, time: now.addingTimeInterval(420))).isEmpty,
                  "raw Pro variants remain different scopes despite the same family label")
    }
}
