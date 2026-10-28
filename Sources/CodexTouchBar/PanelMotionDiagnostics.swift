import AppKit

/// Opt-in integration check using a real status item and NSPopover, with isolated data.
@MainActor
enum PanelMotionDiagnostics {
    private struct Frame: Codable {
        let time: Double
        let window: [Double]
        let content: [Double]
        let clipped: [String]
    }

    static func run(folder: URL) async -> Bool {
        let check = UsageMonitoringDiagnostics.check
        let suite = "CodexTouchBar.PanelMotion." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "UI检查"
        let panel = PanelController()
        defer {
            panel.close(); NSStatusBar.system.removeStatusItem(item)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let now = Date()
            let snapshotWithoutExpiry = UsageSnapshot(fiveHour: .init(kind: .fiveHour, usedPercent: 42, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
                weekly: .init(kind: .weekly, usedPercent: 64, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
                planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false, availableResetCredits: 2, fetchedAt: now)
            let snapshot = UsageSnapshot(fiveHour: snapshotWithoutExpiry.fiveHour, weekly: snapshotWithoutExpiry.weekly,
                planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false,
                availableResetCredits: 2, fetchedAt: now, earliestAvailableResetExpiry: now.addingTimeInterval(86_400))
            let repository = UsageHistoryRepository(url: temporary.appendingPathComponent("history.sqlite"))
            let monitor = UsageMonitoringController(history: repository, preferences: Preferences(defaults: defaults),
                sender: UsageMonitoringUIDiagnostics.FakeNotifications())
            let points = (0...288).map { index in
                UsageMonitoringDiagnostics.point(100 - index % 80, now.timeIntervalSince1970 - 48 * 3_600 + Double(index * 600))
            }
            try await repository.append(points, now: now)
            panel.configureHistory(monitor: monitor, snapshot: { snapshot }, isStale: { false })
            let changes: [UsageWindowKind: UsageRecentChange] = [
                .fiveHour: .init(kind: .fiveHour, duration: 1_800, decrease: 8),
                .weekly: .init(kind: .weekly, duration: 21_600, decrease: 12),
            ]
            panel.update(snapshot: snapshotWithoutExpiry, freshness: .live, error: nil, isRefreshing: false, recentChanges: changes)
            panel.onShowHistory = { [weak panel] in panel?.showHistory() }
            guard let button = item.button else { throw UsageMonitoringDiagnostics.CheckFailure(message: "status button unavailable") }
            // A newly created status item needs a run-loop turn to acquire its menu-bar position.
            try await Task.sleep(for: .milliseconds(200))
            panel.show(relativeTo: button.bounds, of: button)
            try await Task.sleep(for: .milliseconds(650))
            guard let navigation = panel.navigation, let window = navigation.view.window else {
                throw UsageMonitoringDiagnostics.CheckFailure(message: "real popover unavailable")
            }
            try check(panel.isShown && window.isVisible, "real status-item popover is visible")
            panel.update(snapshot: snapshot, freshness: .live, error: nil, isRefreshing: false, recentChanges: changes)
            navigation.view.layoutSubtreeIfNeeded()
            let labels = UIDiagnosticSupport.descendants(navigation.view).compactMap { $0 as? NSTextField }
            guard let expiry = labels.first(where: { $0.stringValue.hasPrefix("最近到期 ") }),
                  let count = labels.first(where: { $0.stringValue == "可用重置：2 次" }) else {
                throw UsageMonitoringDiagnostics.CheckFailure(message: "reset expiry did not appear in the real popover after refresh")
            }
            let expiryRect = navigation.view.convert(expiry.alignmentRect(forFrame: expiry.frame), from: expiry.superview)
            let countRect = navigation.view.convert(count.alignmentRect(forFrame: count.frame), from: count.superview)
            try check(!expiry.isHidden && navigation.view.bounds.contains(expiryRect)
                      && expiryRect.width >= expiry.intrinsicContentSize.width - 1 && expiryRect.minX > countRect.maxX,
                      "reset expiry fits to the right of the count after a live panel update")
            let compact = navigation.view.bounds.size
            let chromeWidth = window.frame.width - compact.width
            let open = UIDiagnosticSupport.descendants(navigation.view).compactMap { $0 as? NSButton }.first { $0.title == "额度图表…" }!
            var traces: [String: [Frame]] = [:]
            for cycle in 0..<3 {
                window.appearance = NSAppearance(named: cycle == 1 ? .aqua : .darkAqua)
                traces["expand-\(cycle)"] = try await trace(navigation, action: { NSApp.sendAction(open.action!, to: open.target, from: open) })
                await panel.waitForHistoryRead()
                try check(panel.isShown && navigation.page == .history && navigation.view.bounds.width == UsageHistoryViewController.panelSize.width,
                          "expanded real popover stays open (shown=\(panel.isShown), page=\(navigation.page), size=\(navigation.view.bounds.size), transitioning=\(navigation.isTransitioning))")
                try check(clippedControls(navigation.view).isEmpty, "expanded controls fit")
                if cycle < 2 { try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("expanded-\(cycle == 1 ? "light" : "dark").png")) }
                if cycle < 2 { try await NativePopoverCapture.capture(window, to: folder.appendingPathComponent("native-history-\(cycle == 1 ? "light" : "dark").png")) }
                let back = UIDiagnosticSupport.descendants(navigation.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "返回额度概览" }!
                traces["return-\(cycle)"] = try await trace(navigation, action: { NSApp.sendAction(back.action!, to: back.target, from: back) })
                try check(panel.isShown && navigation.page == .overview && navigation.view.bounds.size == compact,
                          "return restores real popover (shown=\(panel.isShown), page=\(navigation.page), size=\(navigation.view.bounds.size), expected=\(compact), transitioning=\(navigation.isTransitioning))")
                try check(clippedControls(navigation.view).isEmpty, "overview controls fit")
                if cycle < 2 { try await NativePopoverCapture.capture(window, to: folder.appendingPathComponent("native-overview-\(cycle == 1 ? "light" : "dark").png")) }
            }
            NSApp.sendAction(open.action!, to: open.target, from: open)
            try await Task.sleep(for: .milliseconds(130))
            let back = UIDiagnosticSupport.descendants(navigation.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "返回额度概览" }!
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try check(navigation.isTransitioning, "reversal occurs during the actual animation")
            }
            panel.update(snapshot: snapshot, freshness: .live, error: nil, isRefreshing: false, recentChanges: changes)
            try check(navigation.page == .history, "refresh during expansion does not switch pages")
            let hitRoot = window.contentView!
            let backPoint = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: hitRoot.superview)
            let hit = hitRoot.hitTest(backPoint)
            try check(hit.map { UIDiagnosticSupport.descendants(back).contains($0) } == true, "scaled back button receives pointer hit")
            traces["reverse"] = try await trace(navigation, action: { NSApp.sendAction(back.action!, to: back.target, from: back) })
            try check(navigation.page == .overview && navigation.view.bounds.size == compact, "rapid reversal restores overview")
            try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("overview.png"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(traces).write(to: folder.appendingPathComponent("frames.json"))
            for name in traces.keys.sorted() {
                let frames = traces[name]!
                let clipped = Set(frames.flatMap(\.clipped))
                let topRange = (frames.map { $0.window[1] + $0.window[3] }.max() ?? 0) - (frames.map { $0.window[1] + $0.window[3] }.min() ?? 0)
                let intervals = zip(frames, frames.dropFirst()).map { $1.time - $0.time }
                print("\(name): \(frames.count) samples, max sample interval \(String(format: "%.1f", (intervals.max() ?? 0) * 1_000))ms, window top drift \(String(format: "%.1f", topRange))pt, clipped controls \(clipped.sorted())")
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    try check(Set(frames.map { Int($0.content[0]) }).count >= (name == "reverse" ? 3 : 5), "actual window renders intermediate transition sizes")
                }
                try check(frames.allSatisfy { abs(($0.window[2] - $0.content[0]) - chromeWidth) <= 1 }, "window frame follows the content size")
                try check(topRange <= 1, "popover top stays anchored during transition")
                let widths = frames.map { $0.window[2] }
                try check(zip(widths, widths.dropFirst()).allSatisfy { name.hasPrefix("expand") ? $1 >= $0 : $1 <= $0 }, "window width never reverses during one transition")
            }
            try check(traces.values.flatMap { $0 }.allSatisfy { $0.clipped.isEmpty }, "visible controls fit during actual popover transitions")
            panel.showHistory()
            try await Task.sleep(for: .milliseconds(70))
            panel.close()
            let stoppedSize = navigation.view.bounds.size
            try await Task.sleep(for: .milliseconds(80))
            try check(!panel.isShown && !navigation.isTransitioning && navigation.view.bounds.size == stoppedSize, "closing stops the actual transition")
            panel.show(relativeTo: button.bounds, of: button)
            try await Task.sleep(for: .milliseconds(350))
            try check(panel.isShown && panel.navigation?.page == .overview && panel.navigation?.view.bounds.size == compact, "reopening restores compact overview")
            try await PlanCompatibilityUIDiagnostics.nativePopover(panel, folder: folder)
            panel.update(snapshot: snapshot, freshness: .live, error: nil, isRefreshing: false, recentChanges: changes)
            if CommandLine.arguments.contains("--panel-motion-preview") {
                panel.showHistory(); await panel.waitForHistoryRead()
                if let previewWindow = panel.navigation?.view.window {
                    let identity = ["windowID": previewWindow.windowNumber, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
                    try JSONSerialization.data(withJSONObject: identity).write(to: folder.appendingPathComponent("preview-window.json"))
                }
                print("Preview ready (isolated example data).")
                fflush(stdout)
                try await Task.sleep(for: .seconds(45))
            }
            print("Real menu panel motion self-test passed")
            return true
        } catch {
            print("Real menu panel motion self-test failed: \(error)")
            return false
        }
    }

    private static func trace(_ navigation: MenuPanelNavigationController, action: () -> Void) async throws -> [Frame] {
        let began = ProcessInfo.processInfo.systemUptime
        var frames: [Frame] = []
        action()
        repeat {
            if let window = navigation.view.window {
                let rect = window.frame, size = navigation.view.bounds.size
                frames.append(Frame(time: ProcessInfo.processInfo.systemUptime - began,
                    window: [rect.minX, rect.minY, rect.width, rect.height].map(Double.init),
                    content: [size.width, size.height].map(Double.init), clipped: clippedControls(navigation.view)))
            }
            try await Task.sleep(for: .milliseconds(8))
        } while ProcessInfo.processInfo.systemUptime - began < 0.45
        return frames
    }

    private static func clippedControls(_ root: NSView) -> [String] {
        UIDiagnosticSupport.descendants(root).compactMap { view in
            guard let control = view as? NSControl else { return nil }
            var ancestor: NSView? = control
            while let current = ancestor {
                if current.isHidden || current.alphaValue < 0.02 { return nil }
                ancestor = current.superview
            }
            let rect = root.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
            guard !root.bounds.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
            return control.accessibilityLabel() ?? (control as? NSButton)?.title ?? String(describing: type(of: control))
        }
    }
}
