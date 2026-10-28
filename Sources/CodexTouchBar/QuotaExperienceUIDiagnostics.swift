import AppKit

@MainActor
enum QuotaExperienceUIDiagnostics {
    final class RetrySender: UsageNotificationSending {
        var fail = true
        var hold = false
        var waiting: CheckedContinuation<Void, Never>?
        var accepted: [UsageAlertBatch] = []
        func send(_ batch: UsageAlertBatch) async throws {
            if hold { await withCheckedContinuation { waiting = $0 } }
            try Task.checkCancellation()
            if fail { throw UsageNotificationError.permissionDenied }
            accepted.append(batch)
        }
    }
    static func run(folder: URL) async throws {
        let check = UsageMonitoringDiagnostics.check
        let suite = "CodexTouchBar.QuotaExperience." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences(defaults: defaults)
        let sender = UsageMonitoringUIDiagnostics.FakeNotifications()
        sender.status = .allowed
        // Always the previous minute's twentieth second: +1 stays in that minute.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 40)
        func snapshot(_ five: Int, _ weekly: Int, ago: TimeInterval = 0) -> UsageSnapshot {
            .init(fiveHour: .init(kind: .fiveHour, usedPercent: 100 - five, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
                  weekly: .init(kind: .weekly, usedPercent: 100 - weekly, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(2 * 86_400)),
                  planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false,
                  availableResetCredits: 2, fetchedAt: now.addingTimeInterval(-ago), earliestAvailableResetExpiry: now.addingTimeInterval(43_200))
        }
        let repository = UsageHistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let monitor = UsageMonitoringController(history: repository, preferences: preferences, sender: sender)
        for (remaining, age) in [(80, 1_800.0), (76, 1_200.0), (74, 600.0), (72, 0.0)] {
            monitor.consume(snapshot(remaining, 64, ago: age))
        }
        await monitor.waitForPendingWrites()
        try check(monitor.recentChanges[.fiveHour]?.decrease == 8 && monitor.recentChangesAt == now, "history pipeline publishes matching recent change")
        // A smaller rise in the same minute must survive the database upsert.
        monitor.consume(snapshot(73, 64, ago: -1))
        await monitor.waitForPendingWrites()
        try check(monitor.recentChanges[.fiveHour] == nil, "same-minute rise is a persistent summary break")
        preferences.usageAlertOptions = .init(resetExpiry: true)
        monitor.configure()
        monitor.consume(snapshot(72, 64))
        await monitor.waitForPendingWrites()
        await monitor.waitForPendingDeliveries()
        try check(sender.sent.count == 1 && sender.sent[0].body.contains("到期"), "expiry routes through fake sender only")
        var legacyReminder = try JSONSerialization.jsonObject(with: preferences.usageReminderState!) as! [String: Any]
        legacyReminder["recoveries"] = ["fiveHour": ["target": 80]]
        preferences.usageReminderState = try JSONSerialization.data(withJSONObject: legacyReminder)
        let restarted = UsageMonitoringController(history: repository, preferences: preferences, sender: sender)
        let migrated = try JSONSerialization.jsonObject(with: preferences.usageReminderState!) as! [String: Any]
        try check(migrated["recoveries"] == nil, "controller startup discards retired persisted recovery requests")
        restarted.consume(snapshot(72, 64))
        await restarted.waitForPendingWrites(); await restarted.waitForPendingDeliveries()
        try check(sender.sent.count == 1, "discarding retired requests preserves accepted expiry deduplication")
        let cleared = await restarted.clearHistory()
        try check(cleared && restarted.recentChanges.isEmpty, "clearing history clears summaries")

        // Failed or cancelled submission must not consume opt-in reminders.
        preferences.usageAlertState = nil; preferences.usageReminderState = nil
        let retrySender = RetrySender()
        let failed = UsageMonitoringController(history: repository, preferences: preferences, sender: retrySender)
        failed.consume(snapshot(72, 64))
        await failed.waitForPendingDeliveries()
        let retried = UsageMonitoringController(history: repository, preferences: preferences, sender: retrySender)
        retrySender.fail = false
        retried.consume(snapshot(72, 64))
        await retried.waitForPendingDeliveries()
        retried.consume(snapshot(72, 64))
        await retried.waitForPendingDeliveries()
        try check(retrySender.accepted.count == 1, "expiry retries across restart after permission failure and deduplicates accepted delivery")
        preferences.usageAlertState = nil; preferences.usageReminderState = nil
        retrySender.accepted = []; retrySender.hold = true
        let resumed = UsageMonitoringController(history: repository, preferences: preferences, sender: retrySender)
        resumed.consume(snapshot(72, 64))
        for _ in 0..<100 where retrySender.waiting == nil { await Task.yield() }
        try check(retrySender.waiting != nil, "fake sender holds an expiry delivery")
        resumed.configure()
        retrySender.waiting?.resume(); retrySender.waiting = nil; retrySender.hold = false
        for _ in 0..<10 { await Task.yield() }
        try check(retrySender.accepted.isEmpty, "cancelled expiry delivery remains unacknowledged")
        resumed.consume(snapshot(72, 64, ago: -2))
        await resumed.waitForPendingDeliveries()
        try check(retrySender.accepted.count == 1, "expiry retries after cancelled delivery")
        await failed.waitForPendingWrites(); await retried.waitForPendingWrites(); await resumed.waitForPendingWrites()

        preferences.usageAlertState = nil; preferences.usageReminderState = nil
        preferences.usageAlertOptions = .init(fiveHourRecovery: true, weeklyRecovery: true,
            fiveHourRecoveryThreshold: 80, weeklyRecoveryThreshold: 90)
        let normalSender = UsageMonitoringUIDiagnostics.FakeNotifications()
        let normalRecovery = UsageMonitoringController(history: repository, preferences: preferences, sender: normalSender)
        normalRecovery.consume(snapshot(20, 20, ago: 120))
        normalRecovery.consume(snapshot(80, 90, ago: 60))
        normalRecovery.consume(snapshot(80, 90, ago: 30))
        await normalRecovery.waitForPendingDeliveries(); await normalRecovery.waitForPendingWrites()
        try check(normalSender.sent.count == 1 && normalSender.sent[0].events.count == 2
                  && normalSender.sent[0].events.allSatisfy { $0.reason == .recovered },
                  "settings-based recovery alerts remain enabled for both quotas")

        let panel = PanelController()
        let change = UsageRecentChange(kind: .fiveHour, duration: 1_800, decrease: 8)
        panel.update(snapshot: snapshot(18, 8), freshness: .live, error: nil, isRefreshing: false,
                     recentChanges: [.fiveHour: change], now: now)
        let content = panel.makeContentView()
        let size = content.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        let controls = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSControl }
        let buttons = controls.compactMap { $0 as? NSButton }
        try check(!buttons.contains { $0.title.contains("恢复后提醒") || $0.title.contains("取消100%提醒") },
                  "quota cards no longer expose one-shot reminders")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for state in ["normal", "low", "stale", "missing"] {
                let value: UsageSnapshot? = state == "missing" ? nil : snapshot(state == "normal" ? 87 : 18, state == "normal" ? 64 : 8)
                panel.update(snapshot: value, freshness: state == "stale" ? .stale("test failure") : .live,
                             error: state == "stale" ? "simulated network connection failure" : nil, isRefreshing: false,
                             recentChanges: [.fiveHour: change, .weekly: .init(kind: .weekly, duration: 21_600.0, decrease: 12)],
                             now: state == "normal" ? now.addingTimeInterval(180) : now)
                let fitted = content.fittingSize
                window.setContentSize(fitted)
                try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("quota-\(state)-\(appearance.rawValue).png"))
                try check(fitted.width == 340 && fitted.height < 470, "quota panel remains compact")
                let cards = UIDiagnosticSupport.descendants(content).compactMap { $0 as? QuotaCardView }
                try check(cards.count == 2 && cards.allSatisfy { abs($0.frame.width - 308) < 1 }, "both quota cards fill the panel content width")
                for card in cards {
                    let number = card.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 25 }!
                    let progress = card.subviews.first { String(describing: type(of: $0)) == "QuotaProgressView" }!
                    let numberRect = number.alignmentRect(forFrame: number.frame)
                    let gap = numberRect.minY - progress.frame.maxY
                    print("Quota number/progress gap: \(gap)pt; card height: \(card.frame.height)pt (\(state), \(appearance.rawValue))")
                    try check((6...10).contains(gap), "quota number and progress bar stay close without touching")
                    try check(card.frame.height <= 104, "quota card contains no fixed-height spacer")
                }
                for control in controls where !control.isHidden && !control.ancestorsHidden {
                    let rect = content.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                    try check(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "quota panel controls fit in both appearances")
                }
                let texts = controls.compactMap { ($0 as? NSTextField)?.stringValue }
                try check(!texts.contains(where: { $0.contains("已用") || $0.contains("在线") }), "panel consistently describes remaining quota and observation age")
                if state == "stale" {
                    try check(texts.contains("旧数据，暂不显示近期变化"), "stale panel suppresses summaries")
                }
                if state == "normal" || state == "low" {
                    try check(texts.contains("近30分钟观测下降8%") && texts.contains("近6小时观测下降12%"),
                              "panel uses separate minute and hour summary labels")
                }
            }
        }
        print("Quota experience UI self-test passed (separate summaries, fake expiry delivery, retained settings recovery, panel states)")
    }
}

private extension NSView {
    var ancestorsHidden: Bool { superview.map { $0.isHidden || $0.ancestorsHidden } ?? false }
}
