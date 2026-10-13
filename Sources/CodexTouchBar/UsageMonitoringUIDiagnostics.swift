import AppKit

/// Uses temporary history, isolated preferences and a fake notification service.
/// Never requests real notification permission or reads a ChatGPT window.
@MainActor
enum UsageMonitoringUIDiagnostics {
    final class FakeNotifications: UsageNotificationManaging {
        var status = UsageNotificationPermission.unknown
        var authorizationRequests = 0
        var sent: [UsageAlertBatch] = []
        func permission() async -> UsageNotificationPermission { status }
        func requestIfNeeded() async -> UsageNotificationPermission {
            if status == .unknown { authorizationRequests += 1; status = .denied }
            return status
        }
        func openSystemSettings() {}
        func send(_ batch: UsageAlertBatch) async throws { try Task.checkCancellation(); sent.append(batch) }
    }
    actor Provider: UsageProvider {
        var replies: [Result<UsageSnapshot, Error>]
        init(_ replies: [Result<UsageSnapshot, Error>]) { self.replies = replies }
        func fetch(includeResetCreditDetails: Bool) async throws -> UsageSnapshot { try replies.removeFirst().get() }
    }
    final class Counts: @unchecked Sendable { var alerts = 0; var general = 0 }
    static func run(folder: URL) async -> Bool {
        let check = UsageMonitoringDiagnostics.check
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-ui-tests-" + UUID().uuidString)
        let suite = "CodexTouchBar.UsageUITests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try refreshScheduling()
            try await refreshFeedback()
            let preferences = Preferences(defaults: defaults)
            let service = FakeNotifications()
            let counts = Counts()
            let alertsObserver = NotificationCenter.default.addObserver(forName: Preferences.alertsDidChange, object: nil, queue: nil) { _ in counts.alerts += 1 }
            let generalObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: nil) { _ in counts.general += 1 }
            defer { NotificationCenter.default.removeObserver(alertsObserver); NotificationCenter.default.removeObserver(generalObserver) }
            let settings = UsageAlertSettingsController(preferences: preferences, service: service)
            let content = settings.view
            let settingsPreviewWindow = NSWindow(contentRect: content.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            settingsPreviewWindow.contentView = content
            let checks = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSButton }.filter { $0.title.hasSuffix("提醒") }
            try check(checks.count == 4 && !preferences.usageAlertOptions.anyEnabled && service.authorizationRequests == 0, "four opt-in controls")
            checks[0].performClick(nil)
            for _ in 0..<10 { await Task.yield() }
            try check(preferences.usageAlertOptions.fiveHourLow && service.authorizationRequests == 1, "first enable requests permission")
            checks[0].performClick(nil); checks[0].performClick(nil)
            for _ in 0..<10 { await Task.yield() }
            try check(service.authorizationRequests == 1 && counts.alerts == 3 && counts.general == 0, "permission denial and separate preferences notification")
            try check(Preferences(defaults: defaults).usageAlertOptions.fiveHourLow, "options survive restart")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                settingsPreviewWindow.appearance = NSAppearance(named: appearance)
                try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("alerts-\(appearance.rawValue).png"))
                for control in UIDiagnosticSupport.descendants(content).filter({ $0 is NSControl && !$0.isHidden }) {
                    let rect = content.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                    if !content.bounds.insetBy(dx: -1, dy: -1).contains(rect) {
                        print("Settings control outside layout: \(control), \(rect), bounds \(content.bounds)")
                    }
                    try check(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "settings controls fit")
                }
            }

            let now = Date()
            func snapshot(_ remaining: Int, at time: Date) -> UsageSnapshot {
                .init(fiveHour: .init(kind: .fiveHour, usedPercent: 100 - remaining, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
                      weekly: nil, planType: "plus", limitName: nil, creditBalance: nil, unlimitedCredits: false,
                      availableResetCredits: 0, fetchedAt: time)
            }
            let cached = snapshot(80, at: now.addingTimeInterval(-120))
            let fresh = snapshot(50, at: now.addingTimeInterval(-60))
            let low = snapshot(10, at: now)
            let cache = UsageCache(fileURL: root.appendingPathComponent("cache.json"))
            cache.save(cached)
            let provider = Provider([.success(fresh), .failure(UsageMonitoringDiagnostics.CheckFailure(message: "simulated failure")), .success(low)])
            let store = UsageStore(provider: provider, cache: cache)
            let repository = UsageHistoryRepository(url: root.appendingPathComponent("history.sqlite"))
            let monitor = UsageMonitoringController(history: repository, preferences: preferences, sender: service)
            var samples = 0
            store.onSuccessfulRefresh = { samples += 1; monitor.consume($0) }
            try check(samples == 0, "cache does not sample")
            for _ in 0..<3 {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    store.onChange = { if !store.isRefreshing { store.onChange = nil; done.resume() } }
                    store.refresh()
                }
            }
            await monitor.waitForPendingWrites()
            for _ in 0..<10 { await Task.yield() }
            let saved = try await repository.read(.fiveHour, now: now)
            let missing = try await repository.read(.weekly, now: now)
            try check(samples == 2 && saved.points.count == 2 && missing.points.isEmpty, "only successful fresh windows are sampled")
            try check(service.sent.count == 1 && service.sent[0].events.first?.reason == .low(20), "pipeline sends combined low event to substitute")
            let restarted = UsageMonitoringController(history: repository, preferences: preferences, sender: service)
            restarted.consume(snapshot(9, at: now.addingTimeInterval(1)))
            await restarted.waitForPendingWrites()
            for _ in 0..<10 { await Task.yield() }
            try check(service.sent.count == 1, "persisted state prevents notification replay")
            let cleared = await restarted.clearHistory()
            let empty = try await repository.read(.fiveHour, now: now)
            try check(cleared && empty.points.isEmpty, "clear removes history")
            restarted.consume(snapshot(8, at: now.addingTimeInterval(2)))
            await restarted.waitForPendingWrites()
            for _ in 0..<10 { await Task.yield() }
            try check(service.sent.count == 1, "clear reestablishes baseline")

            var chartSnapshot: UsageSnapshot? = low
            let historyWindow = UsageHistoryWindowController(monitor: monitor, snapshot: { chartSnapshot })
            let chartContent = historyWindow.window!.contentView!
            let chart = UIDiagnosticSupport.descendants(chartContent).compactMap { $0 as? UsageChartView }.first!
            chart.kind = .weekly; chart.end = now
            let fixtures = (0..<20_160).map { index -> UsageObservation in
                var point = UsageMonitoringDiagnostics.point(100 - (index / 120) % 100, now.timeIntervalSince1970 - 14 * 86_400 + Double(index * 60 + 60), kind: .weekly)
                point.rise = index > 0 && index % 12_000 == 0
                return point
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                historyWindow.window?.appearance = NSAppearance(named: appearance)
                historyWindow.display(.init(points: fixtures, notice: nil), kind: .weekly, now: now)
                let began = Date()
                try UIDiagnosticSupport.render(chartContent, to: folder.appendingPathComponent("history-\(appearance.rawValue).png"))
                print("Chart render: 20160 raw samples, \(String(format: "%.3f", Date().timeIntervalSince(began)))s, \(appearance.rawValue)")
            }
            var interrupted: [UsageObservation] = []
            for index in 0..<24 {
                interrupted.append(UsageMonitoringDiagnostics.point(80 - index, now.timeIntervalSince1970 - 44 * 3_600 + Double(index * 600)))
            }
            for index in 0..<24 {
                var point = UsageMonitoringDiagnostics.point(95 - index, now.timeIntervalSince1970 - 20 * 3_600 + Double(index * 600))
                point.rise = index == 0
                interrupted.append(point)
            }
            interrupted.append(UsageMonitoringDiagnostics.point(16, now.timeIntervalSince1970))
            chartSnapshot = snapshot(16, at: now)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                historyWindow.window?.appearance = NSAppearance(named: appearance)
                historyWindow.display(.init(points: interrupted, notice: nil), kind: .fiveHour, now: now)
                try UIDiagnosticSupport.render(chartContent, to: folder.appendingPathComponent("history-dashed-\(appearance.rawValue).png"))
            }
            var dense: [UsageObservation] = []
            for minute in stride(from: 0, through: 1_440, by: 5) {
                let remaining: Int
                switch minute {
                case ..<240: remaining = 26 - minute / 24
                case ..<600: remaining = 100
                case ..<780: remaining = 100 - (minute - 600) * 50 / 180
                case ..<1_000: remaining = 100
                case ..<1_200: remaining = 100 - (minute - 1_000) * 45 / 200
                case ..<1_320: remaining = 100
                case ..<1_410: remaining = 100 - (minute - 1_320) * 45 / 90
                default: remaining = 100
                }
                var point = UsageMonitoringDiagnostics.point(remaining, now.timeIntervalSince1970 - 86_400 + Double(minute * 60))
                point.rise = [240, 780, 1_200, 1_410].contains(minute)
                dense.append(point)
            }
            chartSnapshot = snapshot(100, at: now)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                historyWindow.window?.appearance = NSAppearance(named: appearance)
                historyWindow.display(.init(points: dense, notice: nil), kind: .fiveHour, now: now)
                chartContent.layoutSubtreeIfNeeded()
                let plot = NSRect(x: 50, y: 37, width: chart.bounds.width - 70, height: chart.bounds.height - 89)
                let labels = UsageChartAnnotations.layout(dense, start: now.addingTimeInterval(-48 * 3_600), duration: 48 * 3_600, plot: plot)
                try check(labels.count < 4 && labels.flatMap(\.points).count == 4, "dense labels aggregate without losing events")
                for label in labels {
                    try check(label.rect.minX >= plot.minX && label.rect.maxX <= plot.maxX, "event labels stay inside edge")
                }
                for pair in zip(labels, labels.dropFirst()) { try check(!pair.0.rect.intersects(pair.1.rect), "event labels do not overlap") }
                if let last = labels.last { chart.updateHover(at: NSPoint(x: last.rect.midX, y: last.rect.midY)) }
                try UIDiagnosticSupport.render(chartContent, to: folder.appendingPathComponent("history-dense-\(appearance.rawValue).png"))
                let clear = UIDiagnosticSupport.descendants(chartContent).compactMap { $0 as? NSButton }.first { $0.title == "清空历史记录…" }!
                try check(clear.frame.width < 180, "clear action stays compact")
                let clearBounds = chartContent.convert(clear.alignmentRect(forFrame: clear.frame), from: clear.superview)
                try check(abs(clearBounds.maxX - (chartContent.bounds.maxX - 22)) < 1, "clear action aligns to trailing content edge")
            }
            historyWindow.window!.setContentSize(NSSize(width: 620, height: 420))
            historyWindow.display(.init(points: [], notice: nil), kind: .fiveHour, now: now)
            try UIDiagnosticSupport.render(chartContent, to: folder.appendingPathComponent("history-empty.png"))
            chartSnapshot = snapshot(10, at: now)
            historyWindow.display(.init(points: [UsageMonitoringDiagnostics.point(10, now.timeIntervalSince1970)], notice: nil), kind: .fiveHour, now: now)
            try UIDiagnosticSupport.render(chartContent, to: folder.appendingPathComponent("history-single.png"))
            try check(chart.frame.width > 400 && chart.frame.height >= 190, "resized chart fits")
            print("Usage monitoring UI self-test passed (fake permissions/notifications, refresh pipeline, persistence, rendering)")
            return true
        } catch { print("Usage monitoring UI self-test failed: \(error)"); return false }
    }

    private static func refreshScheduling() throws {
        let check = UsageMonitoringDiagnostics.check
        let timer = QuotaRefreshTimer()
        timer.update(isForeground: false, interval: 300, onFire: {})
        let backgroundDeadline = timer.nextFireDate
        try check(backgroundDeadline != nil, "background timer scheduled")
        for _ in 0..<100 { timer.update(isForeground: false, interval: 300, onFire: {}) }
        try check(timer.nextFireDate == backgroundDeadline, "background app switching preserves refresh deadline")
        timer.update(isForeground: true, interval: 30, onFire: {})
        try check(timer.nextFireDate != nil && timer.nextFireDate! < backgroundDeadline!, "foreground transition reschedules")
        timer.update(isForeground: false, interval: nil, onFire: {})
        try check(timer.nextFireDate == nil, "disabled background timer is absent")
        timer.update(isForeground: true, interval: 120, onFire: {})
        let previous = timer.nextFireDate
        timer.update(isForeground: true, interval: 600, onFire: {})
        try check(timer.nextFireDate != nil && timer.nextFireDate! > previous!, "interval changes reschedule")
        timer.stop()
        try check(timer.nextFireDate == nil, "sleep or termination cancels timer")
    }

    private static func refreshFeedback() async throws {
        let check = UsageMonitoringDiagnostics.check
        let button = QuotaRefreshButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let window = NSWindow(contentRect: button.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = button
        button.layoutSubtreeIfNeeded()
        guard let glyph = button.layer?.sublayers?.first as? CAShapeLayer, let path = glyph.path else {
            throw UsageMonitoringDiagnostics.CheckFailure(message: "refresh glyph must use centred vector geometry")
        }
        let shape = path.boundingBoxOfPath
        try check(abs(shape.midX - glyph.bounds.midX) < 0.001 && abs(shape.midY - glyph.bounds.midY) < 0.001
                  && glyph.anchorPoint == CGPoint(x: 0.5, y: 0.5), "refresh geometry shares its rotation centre")
        let idleColor = glyph.strokeColor
        button.setRefreshing(true)
        try check(!button.isRotating && !button.isEnabled, "hidden panel does not animate")
        button.setPresented(true)
        try check(glyph.strokeColor == idleColor, "refresh keeps idle icon colour")
        try check(button.isRotating && button.layer?.sublayers?.contains(where: { !($0.animationKeys() ?? []).isEmpty }) == true,
                  "visible refresh installs composited rotation")
        button.setRefreshing(false)
        try check(button.isRotating, "fast result retains click feedback")
        try await Task.sleep(nanoseconds: 750_000_000)
        try check(!button.isRotating && button.isEnabled, "minimum feedback then stops")
        button.beginInteraction()
        try check(button.isRotating, "manual click gives immediate feedback")
        button.setPresented(false)
        try check(!button.isRotating, "closing panel stops immediately")
        button.setRefreshing(true); button.setPresented(true)
        try await Task.sleep(nanoseconds: 750_000_000)
        try check(button.isRotating, "slow request keeps rotating past minimum")
        button.setRefreshing(false)
        try check(!button.isRotating, "completed slow request stops")
        button.beginInteraction()
        button.setRefreshing(true)
        try await Task.sleep(nanoseconds: 750_000_000)
        try check(button.isRotating, "new query cancels previous cosmetic stop")
        button.setPresented(false)
        try check(!button.isRotating, "hidden state clears outstanding animation")
    }
}
