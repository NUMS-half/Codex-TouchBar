import AppKit

@MainActor
enum PanelNavigationUIDiagnostics {
    static func run(folder: URL) async throws {
        let check = UsageMonitoringDiagnostics.check
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-navigation-" + UUID().uuidString)
        let suite = "CodexTouchBar.PanelNavigation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences(defaults: defaults)
        let repository = UsageHistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let monitor = UsageMonitoringController(history: repository, preferences: preferences,
                                                 sender: UsageMonitoringUIDiagnostics.FakeNotifications())
        let now = Date()
        let snapshot = UsageSnapshot(fiveHour: .init(kind: .fiveHour, usedPercent: 42, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            weekly: .init(kind: .weekly, usedPercent: 64, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
            planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false, availableResetCredits: 2, fetchedAt: now)
        var records: [UsageObservation] = []
        for index in 0...288 where !(90..<115).contains(index) {
            var point = UsageMonitoringDiagnostics.point(max(0, 100 - (index % 49) * 2), now.timeIntervalSince1970 - 48 * 3_600 + Double(index * 600))
            point.rise = index > 0 && index % 49 == 0
            records.append(point)
        }
        try await repository.append(records, now: now)
        let baseline = try await repository.read(.fiveHour, now: now)
        let panel = PanelController()
        panel.configureHistory(monitor: monitor, snapshot: { snapshot }, isStale: { false })
        panel.update(snapshot: snapshot, freshness: .live, error: nil, isRefreshing: false)
        let navigation = panel.makePresentationController()
        try check(!navigation.view.isOpaque && navigation.view.layer?.backgroundColor == nil,
                  "transition container does not cover the native popover material")
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: navigation.view.bounds.size), styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = navigation.view
        navigation.onResize = { host.setContentSize($0) }
        let overview = navigation.content(for: .overview)!
        let compactSize = navigation.view.bounds.size
        panel.onShowHistory = { panel.showHistory() }
        let open = UIDiagnosticSupport.descendants(overview).compactMap { $0 as? NSButton }.first { $0.title == "额度图表…" }!
        open.performClick(nil)
        await panel.waitForHistoryRead()
        try check(navigation.page == .history && navigation.view.bounds.width == UsageHistoryViewController.panelSize.width, "chart expands inside the existing presentation controller")
        let history = navigation.content(for: .history)!
        let back = UIDiagnosticSupport.descendants(history).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "返回额度概览" }!
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("menu-history-\(appearance.rawValue).png"))
        }
        back.performClick(nil)
        try check(navigation.page == .overview && navigation.view.bounds.size == compactSize, "back restores the compact overview in place")
        try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("menu-overview.png"))
        navigation.show(.history, content: history, size: UsageHistoryViewController.panelSize, animated: true)
        if navigation.isTransitioning {
            navigation.advance(to: 0.5)
            try check(navigation.view.bounds.width > compactSize.width && navigation.view.bounds.width < UsageHistoryViewController.panelSize.width,
                      "transition has an intermediate size, not an immediate window swap")
            try check(overview.superview?.alphaValue == 0 && (history.superview?.alphaValue ?? 0) > 0,
                      "page headings do not overlap midway through expansion")
            try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("menu-transition.png"))
            navigation.show(.overview, content: overview, size: compactSize, animated: true)
            navigation.advance(to: 1)
            try check(navigation.page == .overview && !navigation.isTransitioning && navigation.view.bounds.size == compactSize,
                      "rapid reversal finishes at the right page and size")
            navigation.show(.history, content: history, size: UsageHistoryViewController.panelSize, animated: true)
            navigation.advance(to: 0.4)
            navigation.stop()
            let stoppedSize = navigation.view.bounds.size
            try await Task.sleep(for: .milliseconds(50))
            try check(navigation.view.bounds.size == stoppedSize,
                      "stopping invalidates queued animation ticks")
            navigation.show(.overview, content: overview, size: compactSize, animated: false)
        }
        // Inline confirmation avoids attaching a sheet to a transient popover.
        open.performClick(nil); await panel.waitForHistoryRead()
        let clear = UIDiagnosticSupport.descendants(history).compactMap { $0 as? NSButton }.first { $0.title == "清空历史记录…" }!
        clear.performClick(nil)
        try check(clear.title == "确认清空", "clearing history requires a second explicit action")
        back.performClick(nil)
        try check(clear.title == "清空历史记录…", "leaving the chart cancels pending confirmation")
        let retained = try await repository.read(.fiveHour, now: now)
        try check(retained.points == baseline.points, "navigation and interpolation do not change stored observations")
        navigation.stop()
        print("Menu panel navigation self-test passed (expand, back, intermediate size, reverse, inline confirmation, isolated history)")
    }
}
