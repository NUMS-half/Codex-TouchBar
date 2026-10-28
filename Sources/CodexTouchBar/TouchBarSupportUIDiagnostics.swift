import AppKit

@MainActor
enum TouchBarSupportUIDiagnostics {
    static func settings(folder: URL?) throws {
        let check = UsageMonitoringDiagnostics.check
        let suite = "CodexTouchBar.HardwareSettings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.touchBarConfiguration = .init(slots: [.init(action: .command(.builtIn(.newChat)), customLabel: "保留配置")])
        let saved = preferences.touchBarConfiguration
        let notifications = UsageMonitoringUIDiagnostics.FakeNotifications()
        let login = UnifiedSettingsDiagnostics.LoginItems()
        let controller = SettingsWindowController(preferences: preferences, service: notifications, loginItems: login,
                                                  touchBarSupport: TouchBarSupportChecks.absent)
        let window = controller.window!
        let content = window.contentView!
        let states: [(String, TouchBarSupport)] = [
            ("absent", TouchBarSupportChecks.absent), ("unknown", TouchBarSupportChecks.unknown),
            ("no-api", .init(hardware: .present)), ("present", TouchBarSupportChecks.supported),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (name, support) in states {
                controller.updateTouchBarSupport(support)
                controller.select(.general)
                content.layoutSubtreeIfNeeded()
                let buttons = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
                try check(buttons.contains { $0.title == "显示 Touch Bar" } == support.isUsable, "Touch Bar switch follows hardware capability")
                try check(buttons.contains { $0.title == QuotaRefreshTrigger.touchBar.title } == support.isUsable, "Touch Bar refresh option follows capability")
                try check(window.toolbar?.items.map(\.label) == (support.isUsable ? ["通用", "额度提醒", "快捷操作"] : ["通用", "额度提醒"]),
                          "settings toolbar only lists usable pages")
                let text = UIDiagnosticSupport.descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }
                try check(text.contains(support.settingsDescription), "absence, unknown and API failure have accurate text")
                for trigger in QuotaRefreshTrigger.allCases where trigger != .manual && trigger != .touchBar {
                    try check(buttons.contains { $0.title == trigger.title }, "quota refresh remains available without hardware")
                }
                try check(buttons.contains { $0.title == "登录时启动" }, "login setting remains available")
                try check(controller.shortcuts == nil, "opening general settings never creates or scans the shortcut editor")
                if !support.isUsable {
                    controller.select(.shortcuts) // Default readCatalog=true must still never reach the editor.
                    try check(controller.selectedPage == .general && controller.shortcuts == nil, "unavailable page requests safely fall back")
                }
                try check(preferences.touchBarEnabled && preferences.refreshPolicy.allows(.touchBar)
                          && preferences.touchBarConfiguration == saved, "capability changes preserve all Touch Bar preferences")
                for control in UIDiagnosticSupport.descendants(content).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                    let container = UIDiagnosticSupport.layoutContainer(for: control, root: content)
                    let rect = container.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                    try check(rect.isEmpty || container.bounds.insetBy(dx: -2, dy: -2).contains(rect), "hardware-specific settings fit the window or scroll document")
                }
                if let folder { try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("hardware-settings-\(name)-\(appearance.rawValue).png")) }
            }
        }
        controller.select(.shortcuts, readCatalog: false)
        let editor = controller.shortcuts!
        let field = UIDiagnosticSupport.descendants(editor.view).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.tag == 0 }!
        field.stringValue = "临时草稿"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        controller.updateTouchBarSupport(TouchBarSupportChecks.unknown)
        try check(controller.selectedPage == .general && preferences.touchBarConfiguration == saved, "capability loss exits shortcuts without saving")
        controller.updateTouchBarSupport(TouchBarSupportChecks.supported)
        controller.select(.shortcuts, readCatalog: false)
        try check(field.stringValue == "临时草稿", "transient capability loss retains the editing session")
        controller.updateTouchBarSupport(TouchBarSupportChecks.absent)
        window.close()
        controller.updateTouchBarSupport(TouchBarSupportChecks.supported)
        controller.select(.shortcuts, readCatalog: false)
        try check(field.stringValue == "保留配置", "closing discards an unsaved draft even when the editor is hidden")
        try check(notifications.authorizationRequests == 0 && login.calls == 0, "hardware settings do not request permissions or change login registration")
        window.close()
        print("Touch Bar settings self-test passed (conditional pages, both appearances, preference and draft preservation)")
    }

    static func presentation() throws {
        let check = UsageMonitoringDiagnostics.check
        for (full, fallback) in [(true, true), (false, true), (false, false)] {
            var calls: [String] = []
            let access = TouchBarPresentationAccess(
                present: { _ in calls.append("present"); return full },
                dismiss: { _ in calls.append("dismiss") },
                register: { _ in calls.append("register"); return fallback },
                setPresence: { _, visible in calls.append(visible ? "showStrip" : "hideStrip") },
                unregister: { _ in calls.append("unregister") }
            )
            var controller: TouchBarController? = TouchBarController(presentation: access)
            controller?.setVisible(false)
            try check(calls.isEmpty && controller?.isRunningCountdown == false, "unused controller does not touch private presentation APIs on hide")
            controller?.setVisible(true)
            try check(controller?.isRunningCountdown == (full || fallback), "countdown runs only after a presentation path accepts the request")
            if full || fallback {
                let once = calls
                controller?.setVisible(true)
                try check(calls == once, "repeated refresh cannot register duplicate UI")
            }
            controller?.setVisible(false)
            try check(controller?.isRunningCountdown == false, "hiding stops the Touch Bar countdown")
            let stopped = calls
            controller = nil
            try check(calls == stopped, "explicit cleanup and deinit do not double-remove system resources")
            let expected = full ? ["present", "dismiss"] : (fallback ? ["present", "register", "showStrip", "hideStrip", "unregister"] : ["present", "register"])
            try check(calls == expected, "full, fallback and unavailable paths clean only resources actually registered")
        }
        print("Touch Bar presentation self-test passed (fake APIs, no physical presentation or system changes)")
    }

    static func monitoring() async throws {
        let check = UsageMonitoringDiagnostics.check
        var readouts: [[String]] = []
        for support in [TouchBarSupportChecks.absent, TouchBarSupportChecks.unknown, TouchBarSupportChecks.supported] {
            let suite = "CodexTouchBar.HardwarePipeline." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            let now = Date().addingTimeInterval(-120)
            let first = PlanCompatibilityDiagnostics.snapshot(five: 40, time: now)
            let second = PlanCompatibilityDiagnostics.snapshot(five: 10, time: now.addingTimeInterval(60))
            let provider = PlanCompatibilityUIDiagnostics.Provider([.success(first), .success(second), .failure(UsageServiceError.timedOut)])
            let store = UsageStore(provider: provider, cache: UsageCache(fileURL: root.appendingPathComponent("usage.json")))
            let preferences = Preferences(defaults: defaults)
            preferences.usageAlertOptions = .init(fiveHourLow: true)
            let sender = UsageMonitoringUIDiagnostics.FakeNotifications()
            let history = UsageHistoryRepository(url: root.appendingPathComponent("history.sqlite"))
            let monitor = UsageMonitoringController(history: history, preferences: preferences, sender: sender)
            store.onSuccessfulRefresh = { monitor.consume($0) }
            let session = TouchBarSession()
            var created = 0
            let readout = StatusUsageReadoutView(frame: .zero)
            for index in 0..<3 {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    store.onChange = {
                        session.synchronize(support: support, enabled: true, visible: true) {
                            created += 1; return TouchBarSupportChecks.Presenter()
                        }
                        session.controller?.update(snapshot: store.snapshot, freshness: store.freshness, isRefreshing: store.isRefreshing)
                        readout.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly)
                        if !store.isRefreshing { store.onChange = nil; done.resume() }
                    }
                    store.refresh(includeResetCreditDetails: index == 1)
                }
            }
            await monitor.waitForPendingWrites(); await monitor.waitForPendingDeliveries()
            let points = try await history.read(.fiveHour, now: now.addingTimeInterval(120))
            let requests = await provider.detailRequests
            try check(created == (support.isUsable ? 1 : 0), "quota updates create hardware UI only when supported")
            try check(requests == [false, true, false] && points.points.count == 2 && sender.sent.count == 1,
                      "hardware capability does not change quota requests, real history or low reminders")
            try check(store.snapshot == second && store.freshness.isStale, "failure retains the same quota snapshot in every hardware mode")
            readouts.append(UIDiagnosticSupport.descendants(readout).compactMap { ($0 as? NSTextField)?.stringValue })
            session.stop()
        }
        try check(readouts.allSatisfy { $0 == readouts.first }, "menu readout is identical with, without or unknown Touch Bar hardware")
        print("Touch Bar monitoring self-test passed (same requests, cache state, history, reminders and menu values across hardware modes)")
    }
}
