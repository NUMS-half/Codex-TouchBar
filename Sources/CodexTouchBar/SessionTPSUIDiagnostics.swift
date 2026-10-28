import AppKit

@MainActor
enum SessionTPSUIDiagnostics {
    final class Worker: SessionTPSWorking {
        var starts = 0, stops = 0
        let publish: @Sendable (SessionTPSSnapshot) -> Void
        init(publish: @escaping @Sendable (SessionTPSSnapshot) -> Void) { self.publish = publish }
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }
    static func run(folder: URL) async -> Bool {
        do {
            try UsageMonitoringDiagnostics.check(!UIDiagnosticSupport.descendants(StatusUsageReadoutView()).contains { $0 is NSImageView },
                                                 "menu bar readout removes the app icon")
            try await SessionSelectionChecks.run()
            let check = UsageMonitoringDiagnostics.check
            let suite = "CodexTouchBar.TPS." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = Preferences(defaults: defaults)
            var trusted = false, permissionRequests = 0
            let permissionSettings = SessionTPSSettingsView(preferences: preferences, touchBarSupport: TouchBarSupportChecks.absent,
                accessibilityTrusted: { trusted }, requestAccessibility: { permissionRequests += 1; trusted = true })
            let permissionButton = UIDiagnosticSupport.descendants(permissionSettings).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sessionTPS.accessibility" }!
            try check(!permissionButton.isHidden && permissionRequests == 0, "no automatic Accessibility request")
            permissionButton.performClick(nil)
            try check(permissionRequests == 1 && permissionButton.isHidden, "explicit permission action uses injected fake and refreshes settings")

            let settings = SessionTPSSettingsView(preferences: preferences, touchBarSupport: TouchBarSupportChecks.supported, accessibilityTrusted: { true }, requestAccessibility: {})
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 230), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = settings
            func toggle(_ id: String) -> NSButton {
                UIDiagnosticSupport.descendants(settings).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id }!
            }
            try check(preferences.sessionTPSOptions == .init(), "TPS displays default off")
            defaults.set(true, forKey: "sessionTPS.panel.v2")
            try check(preferences.sessionTPSOptions == .init(menuBar: true), "previous panel display migrates to menu bar, independently of Touch Bar")
            preferences.sessionTPSOptions = .init()
            try check(!preferences.sessionTPSOptions.menuBar, "explicit new preference overrides legacy display")
            settings.refresh()
            toggle("sessionTPS.menuBar").performClick(nil)
            try check(preferences.sessionTPSOptions == .init(menuBar: true), "menu bar only option")
            try check(preferences.sessionTPSOptions.needsObservation(touchBarAvailable: false, touchBarEnabled: false), "menu bar works without Touch Bar")
            var slots = TouchBarConfiguration.defaultSlots
            slots[2] = .init(action: .sessionTPS, customLabel: "ignored")
            preferences.touchBarConfiguration = .init(slots: slots)
            try check(preferences.sessionTPSOptions == .init(menuBar: true, touchBar: true), "slot enables TPS independently of menu bar")
            try check(TouchBarConfiguration.decode(preferences.touchBarConfiguration.encoded()) == preferences.touchBarConfiguration, "TPS slot persists")
            try check(preferences.touchBarConfiguration.slots[2].customLabel == nil, "live readout cannot be renamed")
            toggle("sessionTPS.menuBar").performClick(nil)
            try check(preferences.sessionTPSOptions == .init(touchBar: true), "Touch Bar slot only option")
            try check(!preferences.sessionTPSOptions.needsObservation(touchBarAvailable: false, touchBarEnabled: true), "no monitoring for unavailable Touch Bar alone")
            try check(!preferences.sessionTPSOptions.needsObservation(touchBarAvailable: true, touchBarEnabled: false), "hidden Touch Bar alone does not keep monitoring alive")
            try check(preferences.sessionTPSOptions.needsObservation(touchBarAvailable: true, touchBarEnabled: true), "available configured slot starts observation")
            settings.updateTouchBarSupport(TouchBarSupportChecks.absent)
            try check(preferences.sessionTPSOptions.touchBar, "hardware absence preserves configured slot")
            settings.updateTouchBarSupport(TouchBarSupportChecks.supported)
            let labels = UIDiagnosticSupport.descendants(settings).compactMap { ($0 as? NSButton)?.title }
            try check(!labels.contains(where: { $0.contains("Touch Bar") || $0.contains("输入框") }), "general settings retain only the menu bar switch")
            preferences.touchBarConfiguration = .default
            try check(preferences.sessionTPSOptions == .init(), "replacing last TPS slot disables its observation")
            var workers: [Worker] = []
            let service = SessionTPSService(makeWorker: { _, publish in
                let worker = Worker(publish: publish); workers.append(worker); return worker
            })
            var received = SessionTPSSnapshot()
            service.onChange = { received = $0 }
            service.configure(enabled: false, available: true)
            try check(workers.isEmpty && !service.isRunning, "disabled monitoring creates no worker")
            service.configure(enabled: true, available: false)
            try check(workers.isEmpty, "Codex absence or sleep creates no worker")
            service.configure(enabled: true, available: true)
            service.configure(enabled: true, available: true)
            try check(workers.count == 1 && workers[0].starts == 1, "shared monitor starts exactly once")
            service.configure(enabled: false, available: true)
            try check(workers[0].stops == 1 && !service.isRunning, "last display disabled stops monitor")
            workers[0].publish(.init(phase: .completed, tokensPerSecond: 999, detail: "stale callback"))
            await Task.yield(); await Task.yield()
            try check(received.tokensPerSecond == nil, "late result after shutdown ignored")
            service.configure(enabled: true, available: true)
            try check(workers.count == 2 && service.isRunning, "restart creates fresh observer")
            workers[0].publish(.init(phase: .completed, tokensPerSecond: 999, detail: "old generation"))
            workers[1].publish(.init(phase: .completed, tokensPerSecond: 243, detail: "current generation"))
            for _ in 0..<10 { await Task.yield() }
            try check(received.tokensPerSecond == 243, "restarted monitor accepts only current generation")
            service.configure(enabled: false, available: false)

            var quotaNotifications = 0, tpsNotifications = 0
            let isolated = UsageStore(cache: UsageCache(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
            isolated.onChange = { quotaNotifications += 1 }; isolated.onSessionTPSChange = { tpsNotifications += 1 }
            isolated.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 56))
            isolated.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 56))
            try check(quotaNotifications == 0 && tpsNotifications == 1, "TPS updates neither rebuild quota UI nor repeat unchanged notifications")
            let example = SessionTPSSnapshot(phase: .completed, tokensPerSecond: 243, detail: "合成样本")
            let regularSlot = TouchBarActionSlotView(frame: .init(x: 0, y: 0, width: 68, height: 30))
            regularSlot.layoutSubtreeIfNeeded(); regularSlot.needsLayout = false; regularSlot.needsDisplay = false
            regularSlot.updateSessionTPS(example)
            try check(!regularSlot.needsLayout && !regularSlot.needsDisplay, "TPS does not relayout or repaint ordinary shortcut slots")

            let now = Date()
            let quota = UsageSnapshot(fiveHour: .init(kind: .fiveHour, usedPercent: 69, durationMinutes: 300, resetsAt: now.addingTimeInterval(11_400)),
                weekly: .init(kind: .weekly, usedPercent: 43, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(432_000)),
                planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false, availableResetCredits: 2, fetchedAt: now)
            let panel = PanelController()
            panel.update(snapshot: quota, freshness: .live, error: nil, isRefreshing: false)
            let navigation = panel.makePresentationController()
            let panelWindow = NSWindow(contentRect: navigation.view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            panelWindow.contentView = navigation.view
            navigation.view.layoutSubtreeIfNeeded()
            try check(!UIDiagnosticSupport.descendants(navigation.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("tok/s") },
                      "quota panel no longer contains TPS")
            try MenuBarTPSDiagnostics.run(folder: folder)

            var presentationCalls = 0
            let fake = TouchBarPresentationAccess(present: { _ in presentationCalls += 1; return false }, dismiss: { _ in presentationCalls += 1 },
                register: { _ in presentationCalls += 1; return false }, setPresence: { _, _ in presentationCalls += 1 }, unregister: { _ in presentationCalls += 1 })
            let touchBar = TouchBarController(presentation: fake)
            touchBar.update(snapshot: quota, freshness: .live, isRefreshing: false)
            touchBar.applyConfiguration(.init(slots: slots))
            touchBar.updateSessionTPS(example, enabled: true)
            let item = touchBar.touchBar(NSTouchBar(), makeItemForIdentifier: .init("com.wyx.CodexTouchBar.usage")) as! NSCustomTouchBarItem
            let touchView = item.view
            touchView.frame = .init(x: 0, y: 0, width: TouchBarLayout.width, height: TouchBarLayout.height)
            touchView.layoutSubtreeIfNeeded()
            let slotViews = UIDiagnosticSupport.descendants(touchView).compactMap { $0 as? TouchBarActionSlotView }
            let tpsSlot = slotViews.first { $0.configuration.action == .sessionTPS }!
            let speedButton = UIDiagnosticSupport.descendants(tpsSlot).compactMap { $0 as? NSButton }.first { $0.title == "⚡ 243 tok/s" }!
            try check(tpsSlot.frame.width == TouchBarLayout.actionWidth(for: 656) && slotViews.count == 4, "TPS occupies exactly one existing shortcut slot")
            var actions = 0
            tpsSlot.onAction = { _ in actions += 1 }
            speedButton.performClick(nil)
            try check(actions == 0 && tpsSlot.hitTest(.init(x: 2, y: 2)) == nil, "TPS slot has no click action or hit target")
            try check(presentationCalls == 0 && !touchBar.isRunningCountdown, "offscreen TPS tests never present a physical Touch Bar")
            touchBar.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 999, detail: "new result"), enabled: true)
            try check(speedButton.title == "⚡ 999 tok/s", "configured slot receives subsequent values")
            touchBar.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 100000, detail: "upper bound"), enabled: true)
            let textWidth = (speedButton.title as NSString).size(withAttributes: [.font: speedButton.font!]).width
            try check(textWidth <= tpsSlot.bounds.width - 6, "complete largest supported rate fits the original shortcut slot (text=\(textWidth), slot=\(tpsSlot.bounds.width), font=\(speedButton.font!.pointSize))")
            touchBar.updateSessionTPS(example, enabled: true)
            let touchStage = NSView(frame: touchView.bounds)
            touchStage.wantsLayer = true; touchStage.layer?.backgroundColor = NSColor.black.cgColor
            touchStage.addSubview(touchView)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                panelWindow.appearance = NSAppearance(named: appearance)
                preferences.sessionTPSOptions = .init(menuBar: true, touchBar: true); settings.refresh()
                try UIDiagnosticSupport.render(settings, to: folder.appendingPathComponent("tps-settings-\(appearance.rawValue).png"))
                try UIDiagnosticSupport.render(navigation.view, to: folder.appendingPathComponent("tps-panel-\(appearance.rawValue).png"))
                touchView.appearance = NSAppearance(named: appearance)
                try UIDiagnosticSupport.render(touchStage, to: folder.appendingPathComponent("tps-touchbar-\(appearance.rawValue).png"))
            }
            touchBar.updateSessionTPS(example, enabled: false)
            try check(speedButton.title == "⚡ — tok/s", "unavailable observation leaves configured slot placeholder")
            touchBar.applyConfiguration(.default)
            try check(!slotViews.contains { $0.configuration.action == .sessionTPS }, "replacing slot restores shortcut without changing other slots")
            panelWindow.close(); window.close()
            print("Session TPS UI self-test passed (menu-bar/Touch Bar switches, migration, hardware gating, lifecycle, placement, formatting, fake presentation, appearances)")
            return true
        } catch { print("Session TPS UI self-test failed: \(error)"); return false }
    }
    static func liveProbe() async {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: ApplicationIdentity.chatGPTBundleIdentifier).isEmpty
        let service = SessionTPSService()
        var result = SessionTPSSnapshot()
        let switching = CommandLine.arguments.contains("--session-tps-switch-probe")
        service.onChange = { value in
            if switching && value != result {
                print("TPS switch sample: phase=\(value.phase.rawValue), value=\(value.displayText), status=\(value.detail)")
                fflush(stdout)
            }
            result = value
        }
        service.configure(enabled: true, available: running)
        try? await Task.sleep(for: .seconds(switching ? 40 : 5))
        print("TPS live probe: phase=\(result.phase.rawValue), value=\(result.displayText), status=\(result.detail)")
        service.configure(enabled: false, available: false)
    }
}
