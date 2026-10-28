import AppKit

@MainActor
enum PlanCompatibilityUIDiagnostics {
    actor Provider: UsageProvider {
        private var replies: [Result<UsageSnapshot, Error>]
        private(set) var detailRequests: [Bool] = []
        init(_ replies: [Result<UsageSnapshot, Error>]) { self.replies = replies }
        func fetch(includeResetCreditDetails: Bool) async throws -> UsageSnapshot {
            detailRequests.append(includeResetCreditDetails)
            return try replies.removeFirst().get()
        }
    }
    actor ResetDetailProvider: UsageProvider {
        private let now: Date
        private(set) var requests: [Bool] = []
        init(now: Date) { self.now = now }
        func fetch(includeResetCreditDetails: Bool) async throws -> UsageSnapshot {
            requests.append(includeResetCreditDetails)
            let expiry: Date? = requests.count == 3 || !includeResetCreditDetails ? nil : now.addingTimeInterval(Double(requests.count) * 3_600)
            return PlanCompatibilityDiagnostics.snapshot(plan: "plus", time: now, count: 2, expiry: expiry)
        }
    }

    static func run(folder: URL) async throws {
        try await automaticResetDetails()
        try views(folder: folder)
        try await refreshPipeline()
        print("Plan compatibility UI self-test passed (family tooltips, long names, missing windows, reset details, failed reads, real alert pipeline)")
    }

    private static func automaticResetDetails() async throws {
        let check = UsageMonitoringDiagnostics.check
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-details-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ResetDetailProvider(now: now)
        let store = UsageStore(provider: provider, cache: UsageCache(fileURL: root.appendingPathComponent("usage.json")))
        var policy = QuotaRefreshPolicy()
        policy.setEnabled(false, for: .menuOpen)
        var prohibitedCalls = 0
        try check(!policy.perform(.menuOpen, operation: { prohibitedCalls += 1 }) && prohibitedCalls == 0,
                  "disabled menu-open refresh never starts a request")
        for (index, trigger) in [QuotaRefreshTrigger.launch, .foregroundTimer, .backgroundTimer].enumerated() {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.onChange = { if !store.isRefreshing { store.onChange = nil; done.resume() } }
                _ = policy.perform(trigger) { store.refresh() }
            }
            let expected: Date? = index == 2 ? nil : now.addingTimeInterval(Double(index + 1) * 3_600)
            try check(store.snapshot?.earliestAvailableResetExpiry == expected,
                      "regular refresh uses its own reset expiry and never reuses stale details")
        }
        let requests = await provider.requests
        try check(requests == [true, true, true], "each permitted refresh requests details in one fetch")
    }

    static func nativePopover(_ panel: PanelController, folder: URL) async throws {
        let check = UsageMonitoringDiagnostics.check
        guard let navigation = panel.navigation, let window = navigation.view.window else {
            throw UsageMonitoringDiagnostics.CheckFailure(message: "native plan preview requires a presented popover")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (name, value) in [
                ("weekly-only", PlanCompatibilityDiagnostics.snapshot(plan: "promax", five: nil, time: Date())),
                ("long-name", PlanCompatibilityDiagnostics.snapshot(plan: String(repeating: "Future plan ", count: 12), time: Date())),
            ] {
                panel.update(snapshot: value, freshness: .live, error: nil, isRefreshing: false)
                navigation.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                try check(navigation.view.bounds.width == 340 && panel.isShown, "plan changes retain the native popover size")
                for control in UIDiagnosticSupport.descendants(navigation.view).compactMap({ $0 as? NSControl }) {
                    let rect = navigation.view.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                    if !control.isHiddenOrHasHiddenAncestor && !rect.isEmpty {
                        try check(navigation.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "native plan controls fit the full popover")
                    }
                }
                try await NativePopoverCapture.capture(window, to: folder.appendingPathComponent("native-plan-\(name)-\(appearance.rawValue).png"))
            }
        }
    }

    private static func views(folder: URL) throws {
        let check = UsageMonitoringDiagnostics.check
        let panel = PanelController()
        let content = panel.makeContentView()
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = content
        let now = Date()
        let longName = String(repeating: "Future plan with a longer name ", count: 8)
        let values: [(String, UsageSnapshot?)] = [
            ("unread", nil),
            ("weekly-only", PlanCompatibilityDiagnostics.snapshot(plan: "promax", five: nil, time: now)),
            ("five-only", PlanCompatibilityDiagnostics.snapshot(plan: "go", weekly: nil, time: now, count: 0)),
            ("empty", PlanCompatibilityDiagnostics.snapshot(five: nil, weekly: nil, time: now)),
            ("pro", PlanCompatibilityDiagnostics.snapshot(plan: "prolite", time: now, count: 2)),
            ("reset-expiry", PlanCompatibilityDiagnostics.snapshot(plan: "plus", time: now, count: 2, expiry: now.addingTimeInterval(86_400))),
            ("unknown", PlanCompatibilityDiagnostics.snapshot(plan: longName, time: now)),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            for (name, value) in values {
                panel.update(snapshot: value, freshness: .live, error: nil, isRefreshing: false, now: now)
                let size = content.fittingSize
                host.setContentSize(size)
                content.layoutSubtreeIfNeeded()
                try check(size.width == 340 && size.height < 470, "all plan states retain the compact panel")
                let labels = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSTextField }
                let texts = labels.map(\.stringValue)
                if name == "reset-expiry" {
                    guard let expiry = labels.first(where: { $0.stringValue.hasPrefix("最近到期 ") }) else {
                        throw UsageMonitoringDiagnostics.CheckFailure(message: "future reset expiry label missing from panel hierarchy")
                    }
                    let frame = content.convert(expiry.alignmentRect(forFrame: expiry.frame), from: expiry.superview)
                    print("Reset expiry label: hidden=\(expiry.isHiddenOrHasHiddenAncestor), frame=\(frame), intrinsic=\(expiry.intrinsicContentSize)")
                    try check(!expiry.isHiddenOrHasHiddenAncestor && content.bounds.contains(frame)
                              && frame.width >= expiry.intrinsicContentSize.width - 1,
                              "future reset expiry is fully visible alongside reset count")
                }
                let cards = UIDiagnosticSupport.descendants(content).compactMap { $0 as? QuotaCardView }
                let cardTexts = cards.flatMap { UIDiagnosticSupport.descendants($0).compactMap { ($0 as? NSTextField)?.stringValue } }
                let missing = [value?.fiveHour, value?.weekly].filter { $0 == nil }.count
                let caption = value == nil ? "尚未读取额度" : "未提供此窗口数据"
                try check(cardTexts.filter { $0 == caption }.count == missing && cardTexts.filter { $0 == "—" }.count == missing,
                          "unread and absent windows are distinct (state=\(name), expectedMissing=\(missing), texts=\(texts))")
                let resetText = value?.availableResetCredits.map { "可用重置：\($0) 次" } ?? "可用重置：—"
                try check(texts.contains(resetText), "unknown, zero and positive counts have distinct text")
                if let raw = value?.planType {
                    guard let tagLabel = labels.first(where: { $0.toolTip == "套餐类型：\(raw)" }) else {
                        throw UsageMonitoringDiagnostics.CheckFailure(message: "raw plan tooltip missing")
                    }
                    try check(tagLabel.stringValue == displayPlanName(raw), "family label preserves raw type in tooltip")
                    try check(tagLabel.superview!.frame.width <= 130.1, "long unknown plan names stay inside the tag")
                }
                try check(!texts.contains("N/A") && !texts.contains("当前方案未提供"), "missing windows do not assert missing plan rights")
                try check(cards.count == 2 && cards.allSatisfy { abs($0.frame.width - 308) < 1 }, "both existing cards retain their width")
                try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("plan-\(name)-\(appearance.rawValue).png"))
            }
        }
        let card = QuotaCardView(kind: .fiveHour)
        card.update(PlanCompatibilityDiagnostics.snapshot(time: now).fiveHour)
        card.update(nil, hasSnapshot: true)
        try check(UIDiagnosticSupport.descendants(card).compactMap { ($0 as? NSTextField)?.toolTip }.isEmpty,
                  "removed windows do not leave old countdown tooltips")
        let readout = StatusUsageReadoutView(frame: .zero)
        readout.update(fiveHour: nil, weekly: nil)
        try check(UIDiagnosticSupport.descendants(readout).compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0 == "—" }.count == 2,
                  "menu bar missing values remain neutral")
    }

    private static func refreshPipeline() async throws {
        let check = UsageMonitoringDiagnostics.check
        let suite = "CodexTouchBar.PlanCompatibility." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 600)
        func value(_ seconds: Double, five: Int? = 80, weekly: Int? = 60) -> UsageSnapshot {
            PlanCompatibilityDiagnostics.snapshot(plan: "pro", five: five, weekly: weekly,
                                                  time: now.addingTimeInterval(seconds), count: 1)
        }
        let first = value(0)
        let cache = UsageCache(fileURL: root.appendingPathComponent("usage.json"))
        cache.save(PlanCompatibilityDiagnostics.snapshot(plan: "plus", time: now.addingTimeInterval(-60),
                                                        count: 1, expiry: Date().addingTimeInterval(3_600)))
        let provider = Provider([.success(first), .success(value(60, five: nil, weekly: 55)),
            .failure(UsageServiceError.timedOut), .success(value(180, five: 5, weekly: 50)),
            .success(value(240, five: 40, weekly: 45)), .failure(UsageServiceError.timedOut),
            .success(value(360, five: 10, weekly: 40)), .success(value(420, five: nil, weekly: nil)),
            .success(value(480, five: 100, weekly: 100))])
        let store = UsageStore(provider: provider, cache: cache)
        try check(store.freshness == .cached && store.snapshot?.earliestAvailableResetExpiry != nil,
                  "existing cached values stay visibly cached")
        let preferences = Preferences(defaults: defaults)
        preferences.usageAlertOptions = .init(fiveHourLow: true, weeklyLow: true, fiveHourRecovery: true, weeklyRecovery: true)
        let sender = UsageMonitoringUIDiagnostics.FakeNotifications()
        let repository = UsageHistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let monitor = UsageMonitoringController(history: repository, preferences: preferences, sender: sender)
        store.onSuccessfulRefresh = { monitor.consume($0) }
        let requestedDetails = [false, true, false, true, false, false, true, false, true]
        var previous: UsageSnapshot?
        for index in requestedDetails.indices {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.onChange = { if !store.isRefreshing { store.onChange = nil; done.resume() } }
                store.refresh(includeResetCreditDetails: requestedDetails[index])
            }
            await monitor.waitForPendingWrites()
            await monitor.waitForPendingDeliveries()
            if [2, 5].contains(index) {
                try check(store.snapshot == previous && store.freshness.isStale && store.errorMessage != nil,
                          "failed reads retain the snapshot and alert baseline")
            } else {
                try check(store.freshness == .live && store.errorMessage == nil, "successful missing-window reads remain live")
            }
            if index == 0 {
                try check(store.snapshot == first && store.snapshot?.earliestAvailableResetExpiry == nil,
                          "equal counts never carry the previous plan's expiry into a new read")
            }
            if index == 1 { try check(store.snapshot?.fiveHour == nil, "a removed window clears its last visible value") }
            if index == 3 { try check(sender.sent.isEmpty, "returning low window only establishes a baseline") }
            if index == 6 {
                try check(sender.sent.count == 1 && sender.sent[0].events.first?.reason == .low(20),
                          "a failed read does not erase the next real low crossing")
            }
            previous = store.snapshot
        }
        try check(sender.sent.count == 1 && store.snapshot?.fiveHour?.remainingPercent == 100,
                  "windows returning after an empty success do not emit fake recovery alerts")
        let five = try await repository.read(.fiveHour, now: now.addingTimeInterval(480))
        let weekly = try await repository.read(.weekly, now: now.addingTimeInterval(480))
        try check(five.points.count == 5 && weekly.points.count == 6,
                  "only actual windows from successful reads reach history")
        let details = await provider.detailRequests
        try check(details == requestedDetails, "the store forwards detail requests without adding extra reads")
    }
}
