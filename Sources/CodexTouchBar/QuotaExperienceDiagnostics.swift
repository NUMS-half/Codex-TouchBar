import Foundation

enum QuotaExperienceDiagnostics {
    static func run() throws {
        let check = UsageMonitoringDiagnostics.check
        let now = Date(timeIntervalSince1970: 100_000)
        func point(_ remaining: Int, _ secondsAgo: Double = 0, kind: UsageWindowKind = .fiveHour) -> UsageObservation {
            UsageMonitoringDiagnostics.point(remaining, now.timeIntervalSince1970 - secondsAgo,
                kind: kind, reset: now.timeIntervalSince1970 + 3_600)
        }
        let series = [point(80, 1_800), point(76, 1_200), point(74, 600), point(72)]
        try check(UsageRecentChange.summarize(series, current: point(72)) == .init(kind: .fiveHour, duration: 1_800, decrease: 8), "recent change uses observed percentage points")
        try check(UsageRecentChange.summarize([point(80, 1_800), point(72)], current: point(72)) == nil, "sampling gap prevents misleading change")
        try check(UsageRecentChange.summarize([point(80, 600)], current: point(72)) == nil, "short sample has no summary")
        try check(UsageRecentChange.summarize([point(80, 1_800), point(78, 1_200), point(79, 600)], current: point(72)) == nil, "even small recovery breaks consumption segment")
        var scope = point(76, 1_200); scope.plan = "pro"
        try check(UsageRecentChange.summarize([series[0], scope, series[2]], current: point(72)) == nil, "plan change breaks segment")
        scope = point(76, 1_200); scope.reset = now.addingTimeInterval(7_200)
        try check(UsageRecentChange.summarize([series[0], scope, series[2]], current: point(72)) == nil, "reset changes break segment")
        scope = point(76, 1_200); scope.plan = nil
        try check(UsageRecentChange.summarize([series[0], scope, series[2]], current: point(72)) == nil, "unknown scope is not bridged")
        try check(UsageRecentChange.summarize(series, current: point(72, kind: .weekly)) == nil, "windows never share samples")
        let weekly = stride(from: 3_600, through: 0, by: -600).map { point(70 + $0 / 600, Double($0), kind: .weekly) }
        try check(UsageRecentChange.summarize(weekly, current: point(70, kind: .weekly))?.text == "近1小时观测下降6%", "partial weekly span is labeled honestly")
        let halfHour = UsageRecentChange.summarize(series, current: point(72))!
        try check(halfHour.text == "近30分钟观测下降8%", "5H always uses minutes and percent notation")
        let bounded = UsageRecentChange.summarize([point(85, 2_100), point(80, 1_500), point(75, 900), point(70)], current: point(70))
        try check(bounded?.duration == 1_500 && bounded?.decrease == 10, "5H never borrows observations before its thirty-minute window")
        let daily = stride(from: 93_600, through: 0, by: -600).map { point(70 + $0 / 3_600, Double($0), kind: .weekly) }
        let dailyChange = UsageRecentChange.summarize(daily, current: point(70, kind: .weekly))
        try check(dailyChange?.text == "近24小时观测下降24%", "weekly independently summarizes its last twenty-four hours")
        let fractional = UsageRecentChange(kind: .weekly, duration: 369 * 60, decrease: 12)
        try check(fractional.text == "近6.2小时观测下降12%", "weekly partial hours are shown in hours, never minutes")
        try check(UsageRecentChange(kind: .fiveHour, duration: 1_800, decrease: 0).text == "近30分钟观测无变化",
                  "zero change stays explicit")
        let shortWeekly = stride(from: 2_700, through: 0, by: -300).map { point(70 + $0 / 300, Double($0), kind: .weekly) }
        try check(UsageRecentChange.summarize(shortWeekly, current: point(70, kind: .weekly)) == nil,
                  "weekly requires at least one hour of continuous observations")
        try check(formatResetCountdown(now, now: now) == "待查询确认重置" && formatResetCountdown(nil, now: now) == "重置时间暂无", "zero countdown does not claim recovery")
        try check(formatResetCountdown(now.addingTimeInterval(59), now: now) == "不到1分后重置", "subminute reset remains in the future")
        try check(formatObservationAge(now.addingTimeInterval(-120), now: now) == "2分钟前更新", "freshness uses observation age")

        func snapshot(_ remaining: Int, _ seconds: Double, expiry: Date? = nil, count: Int = 1) -> UsageSnapshot {
            .init(fiveHour: .init(kind: .fiveHour, usedPercent: 100 - remaining, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
                  weekly: .init(kind: .weekly, usedPercent: 100, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
                  planType: "plus", limitName: nil, creditBalance: nil, unlimitedCredits: false,
                  availableResetCredits: count, fetchedAt: now.addingTimeInterval(seconds), earliestAvailableResetExpiry: expiry)
        }
        var reminders = UsageReminderEngine()
        let retired = Data(#"{"recoveries":{"fiveHour":{"target":80}},"expiryEnabled":false}"#.utf8)
        reminders = try JSONDecoder().decode(UsageReminderEngine.self, from: retired)
        try check(reminders.consume(snapshot(100, 60), now: now.addingTimeInterval(60)).isEmpty,
                  "retired recovery requests cannot trigger notifications")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reminders)) as! [String: Any]
        try check(encoded["recoveries"] == nil, "retired requests are removed from persisted state")

        let expiry = now.addingTimeInterval(86_400)
        try check(reminders.consume(snapshot(0, 0, expiry: expiry), now: now).isEmpty, "expiry reminder defaults off")
        reminders.configure(expiryEnabled: true)
        try check(reminders.consume(snapshot(0, 0, expiry: expiry.addingTimeInterval(1)), now: now).isEmpty, "expiry outside 24h does not notify")
        let event = reminders.consume(snapshot(0, 0, expiry: expiry), now: now)
        try check(event.count == 1 && event.first?.reason == .resetExpiring(expiry), "expiry boundary is included")
        reminders.acknowledge(event)
        reminders = try JSONDecoder().decode(UsageReminderEngine.self, from: JSONEncoder().encode(reminders))
        try check(reminders.consume(snapshot(0, 60, expiry: expiry), now: now.addingTimeInterval(60)).isEmpty, "expiry deduplicates across restart")
        try check(reminders.consume(snapshot(0, 120, expiry: now), now: now.addingTimeInterval(120)).isEmpty, "already expired credit is not notified")
        try check(reminders.consume(snapshot(0, 120, expiry: expiry.addingTimeInterval(-60), count: 0), now: now.addingTimeInterval(120)).isEmpty, "no credit means no expiry alert")
        let legacy = try JSONDecoder().decode(UsageAlertOptions.self, from: Data("{}".utf8))
        try check(!legacy.resetExpiry && !legacy.anyEnabled, "existing alert preferences retain opt-in defaults")
        print("Quota experience self-test passed (separate quota summaries, countdowns, retired requests, expiry deduplication)")
    }
}
