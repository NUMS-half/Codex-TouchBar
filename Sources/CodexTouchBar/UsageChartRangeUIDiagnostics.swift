import AppKit

@MainActor
enum UsageChartRangeUIDiagnostics {
    static func run(folder: URL) throws {
        let check = UsageMonitoringDiagnostics.check
        let suite = "CodexTouchBar.ChartRange." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temporary) }
        let monitor = UsageMonitoringController(history: UsageHistoryRepository(url: temporary.appendingPathComponent("history.sqlite")),
            preferences: Preferences(defaults: defaults), sender: UsageMonitoringUIDiagnostics.FakeNotifications())
        let controller = UsageHistoryViewController(monitor: monitor, snapshot: { nil })
        try check(!controller.view.isOpaque && !(controller.view is NSVisualEffectView),
                  "history leaves the popover's own material visible without an extra effect layer")
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: UsageHistoryViewController.panelSize),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = controller.view
        let controls = UIDiagnosticSupport.descendants(controller.view)
        let chart = controls.compactMap { $0 as? UsageChartView }.first!
        let selector = controls.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "5H显示范围" }!
        let kind = controls.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "额度类型" }!
        let now = Date()
        let start = now.addingTimeInterval(-48 * 3_600)
        let points = (0...2_880).map { index -> UsageObservation in
            var point = UsageMonitoringDiagnostics.point(100 - (index % 300) / 3,
                start.timeIntervalSince1970 + Double(index * 60), reset: start.timeIntervalSince1970 + Double((index / 300 + 1) * 300 * 60))
            point.rise = index > 0 && index % 300 == 0
            return point
        }
        controller.display(.init(points: points, notice: nil), kind: .fiveHour, now: now)
        try check(chart.range == .sixHours && selector.selectedSegment == 0, "first chart uses the fine six-hour view")
        for (index, range) in UsageChartRange.fiveHourOptions.enumerated() {
            selector.selectedSegment = index
            NSApp.sendAction(selector.action!, to: selector.target, from: selector)
            try check(chart.range == range && chart.points == points && chart.end == now, "range change reuses original local observations")
            controller.display(.init(points: points, notice: nil), kind: .fiveHour, now: now)
            try check(chart.range == range, "refresh preserves the chosen range")
            controller.view.layoutSubtreeIfNeeded()
            let plot = NSRect(x: 50, y: 37, width: chart.bounds.width - 70, height: chart.bounds.height - 89)
            let visibleStart = now.addingTimeInterval(-range.duration)
            let buckets = UsageChartBucket.make(points, range: range, start: visibleStart, end: now)
            let target = buckets[buckets.count / 2]
            let time = max(visibleStart, target.start).addingTimeInterval(min(range.bucketInterval / 2, target.end.timeIntervalSince(max(visibleStart, target.start)) / 2))
            chart.updateHover(at: NSPoint(x: plot.minX + CGFloat(time.timeIntervalSince(visibleStart) / range.duration) * plot.width, y: plot.midY))
            try check(chart.accessibilityHelp()?.contains("剩余\(target.remaining)%") == true, "hover maps through the selected time scale")
            chart.updateHover(at: NSPoint(x: -1, y: -1))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance)
                try UIDiagnosticSupport.render(controller.view, to: folder.appendingPathComponent("range-\(index)-\(appearance.rawValue).png"))
                for control in controls.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                    let rect = controller.view.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                    try check(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "time-range controls fit the compact panel")
                }
            }
        }
        controller.display(.init(points: [], notice: nil), kind: .weekly, now: now)
        try check(chart.range == .tenDays && selector.isHidden && kind.selectedSegment == 1, "weekly stays at ten days and hides 5H zoom")
        controller.display(.init(points: points, notice: nil), kind: .fiveHour, now: now)
        try check(chart.range == .twelveHours && !selector.isHidden, "returning from weekly restores the last 5H range")
        selector.selectedSegment = 0; NSApp.sendAction(selector.action!, to: selector.target, from: selector)
        let oldPoint = UsageMonitoringDiagnostics.point(55, now.addingTimeInterval(-8 * 3_600).timeIntervalSince1970)
        controller.display(.init(points: [oldPoint], notice: nil), kind: .fiveHour, now: now)
        host.appearance = NSAppearance(named: .aqua)
        try UIDiagnosticSupport.render(controller.view, to: folder.appendingPathComponent("range-empty-recent.png"))
        try check(UsageChartBucket.make(chart.points, range: chart.range, start: now.addingTimeInterval(-chart.range.duration), end: now).isEmpty,
                  "older records do not leak into the six-hour view")
        selector.selectedSegment = 1; NSApp.sendAction(selector.action!, to: selector.target, from: selector)
        try check(UsageChartBucket.make(chart.points, range: chart.range, start: now.addingTimeInterval(-chart.range.duration), end: now).first?.remaining == 55,
                  "widening an empty recent view reveals retained older history")
        print("Chart range UI self-test passed (6/12 hours, retained raw data, hover mapping, weekly, light/dark)")
    }
}
