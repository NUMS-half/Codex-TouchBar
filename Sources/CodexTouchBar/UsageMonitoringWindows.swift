import AppKit

private final class UsageWindowBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let monitor: UsageMonitoringController
    private let snapshot: () -> UsageSnapshot?
    private let isStale: () -> Bool
    private let chart = UsageChartView(frame: .zero)
    private let selector = NSSegmentedControl(labels: ["5H · 最近48小时", "周 · 最近14天"], trackingMode: .selectOne, target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: "清空历史记录…", target: nil, action: nil)
    private var kind = UsageWindowKind.fiveHour
    private var readTask: Task<Void, Never>?
    private var generation = 0
    private var displayTimer: Timer?

    init(monitor: UsageMonitoringController, snapshot: @escaping () -> UsageSnapshot?, isStale: @escaping () -> Bool = { false }) {
        self.monitor = monitor; self.snapshot = snapshot; self.isStale = isStale
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "额度变化曲线"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 400)
        super.init(window: window)
        window.delegate = self
        window.contentView = UsageWindowBackgroundView(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
        guard let root = window.contentView else { return }
        selector.selectedSegment = 0; selector.target = self; selector.action = #selector(selectKind)
        clearButton.target = self; clearButton.action = #selector(clearHistory)
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let explanation = NSTextField(wrappingLabelWithString: "纵轴为剩余额度，下降表示消耗。实线连接连续记录，虚线连接空档、口径变化或回升，仅为估计；悬停显示最近实测值。")
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        for view in [selector, summary, chart, explanation, status, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), selector.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            summary.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 16),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chart.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8), chart.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            chart.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            explanation.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4), explanation.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            status.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 7), status.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -12),
            clearButton.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 7), clearButton.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            clearButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16), status.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    func show(kind requested: UsageWindowKind? = nil) {
        if let requested { kind = requested }
        selector.selectedSegment = kind == .fiveHour ? 0 : 1
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        displayTimer?.tolerance = 5
        reload()
    }

    func reload() {
        guard window?.isVisible == true else { return }
        generation += 1; let ticket = generation; let selected = kind; let now = Date()
        readTask?.cancel()
        readTask = Task { [weak self, monitor] in
            do {
                let result = try await monitor.history.read(selected, now: now)
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.display(result, kind: selected, now: now)
            } catch {
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.chart.points = []
                self.status.stringValue = "历史记录读取失败；当前额度显示不受影响。"
            }
        }
    }
    func display(_ result: UsageHistoryResult, kind selected: UsageWindowKind, now: Date) {
        kind = selected; selector.selectedSegment = selected == .fiveHour ? 0 : 1
        chart.kind = selected; chart.end = now; chart.points = result.points
        let value = snapshot()
        let windowValue = selected == .fiveHour ? value?.fiveHour : value?.weekly
        let latest = result.points.last
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm:ss"
        let balance = windowValue.map { "\($0.remainingPercent)%" } ?? "—"
        let updated = latest.map { formatter.string(from: $0.time) } ?? "—"
        let first = result.points.first.map { formatter.string(from: $0.time) } ?? "—"
        summary.stringValue = "最近查询余额：\(balance)    最新成功记录：\(updated)\n范围内记录起点：\(first)"
        chart.setAccessibilityValue("\(selected.accessibleTitle)，最近查询余额 \(balance)，\(result.points.count) 个历史采样")
        let stale = isStale() || (latest.map { now.timeIntervalSince($0.time) > 900 } ?? false)
        status.stringValue = monitor.historyError ?? result.notice
            ?? (stale ? "当前额度尚未更新或最近记录超过15分钟，曲线显示已有历史。" : "历史保存在本机；5H保留48小时，周额度保留14天。")
    }
    @objc private func selectKind() { kind = selector.selectedSegment == 0 ? .fiveHour : .weekly; reload() }
    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空两条额度历史？"
        alert.informativeText = "将删除5H和周额度的历史，并重新建立提醒基线。之后从新的成功查询开始记录。"
        alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard let self else { return }
                self.clearButton.isEnabled = false
                _ = await self.monitor.clearHistory()
                self.clearButton.isEnabled = true; self.reload()
            }
        }
    }
    func windowWillClose(_ notification: Notification) { displayTimer?.invalidate(); displayTimer = nil; readTask?.cancel() }
}

private final class PercentageSettingView: NSView, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    private let stepper = NSStepper(frame: .zero)
    private var value: Int
    var onChange: ((Int) -> Void)?
    init(value: Int, index: Int, label: String) {
        self.value = value
        super.init(frame: .zero)
        field.tag = index; stepper.tag = index
        field.delegate = self; field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel(label)
        field.toolTip = "请输入1～100的整数百分比"
        stepper.minValue = 1; stepper.maxValue = 100; stepper.increment = 1
        stepper.target = self; stepper.action = #selector(stepped)
        stepper.setAccessibilityLabel(label + "微调")
        let percent = NSTextField(labelWithString: "%")
        percent.font = .systemFont(ofSize: 12); percent.textColor = .secondaryLabelColor
        for child in [field, percent, stepper] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26), widthAnchor.constraint(equalToConstant: 104),
            field.leadingAnchor.constraint(equalTo: leadingAnchor), field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 56), field.heightAnchor.constraint(equalToConstant: 24),
            percent.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 5), percent.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor), stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(value, enabled: false)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ new: Int, enabled: Bool) {
        value = new; field.integerValue = new; stepper.integerValue = new
        field.textColor = .labelColor; field.isEnabled = enabled; stepper.isEnabled = enabled
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let new = Int(field.stringValue), (1...100).contains(new) else {
            field.textColor = .systemOrange; return
        }
        field.textColor = .labelColor
        if value != new { value = new; stepper.integerValue = new; onChange?(new) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        controlTextDidChange(notification)
        field.integerValue = value; field.textColor = .labelColor
    }
    @objc private func stepped() {
        value = stepper.integerValue; field.integerValue = value; field.textColor = .labelColor
        onChange?(value)
    }
}

@MainActor
final class UsageAlertSettingsController: NSViewController {
    private let preferences: Preferences
    private let service: any UsageNotificationManaging
    private let checks: [NSButton] = ["5H低额提醒", "周低额提醒", "5H恢复提醒", "周恢复提醒"].map {
        NSButton(checkboxWithTitle: $0, target: nil, action: nil)
    }
    private var thresholds: [PercentageSettingView] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let settings = NSButton(title: "打开系统通知设置…", target: nil, action: nil)

    init(preferences: Preferences = .shared, service: any UsageNotificationManaging) {
        self.preferences = preferences; self.service = service
        super.init(nibName: nil, bundle: nil); _ = view
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = UsageWindowBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let root = view
        let rules = NSTextField(wrappingLabelWithString: "阈值范围1%～100%，修改自动保存。连续处于同一状态只提醒一次；开启或修改阈值后，从下一次成功查询建立基线。恢复需再查询确认，后台通常延迟5～10分钟。")
        rules.font = .systemFont(ofSize: 12); rules.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12); status.stringValue = "正在检查通知权限…"
        settings.isHidden = true
        var rows: [NSView] = []
        for index in 0..<4 {
            let input = PercentageSettingView(value: index < 2 ? 20 : 100, index: index, label: checks[index].title + "阈值")
            input.onChange = { [weak self] value in self?.setThreshold(value, index: index) }
            thresholds.append(input)
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let comparison = NSTextField(labelWithString: index < 2 ? "低于" : "达到")
            comparison.font = .systemFont(ofSize: 12); comparison.textColor = .secondaryLabelColor
            let row = NSStackView(views: [checks[index], spacer, comparison, input])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            rows.append(row)
        }
        func column(_ views: [NSView]) -> NSStackView {
            let result = NSStackView(views: views)
            result.orientation = .vertical; result.alignment = .leading; result.spacing = 10
            result.widthAnchor.constraint(equalToConstant: root.bounds.width - 36).isActive = true
            views.forEach { $0.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
            return result
        }
        let low = SettingsGroupView(title: "低额提醒", subtitle: "剩余额度低于设定值时提醒一次，默认20%。", controls: [column(Array(rows.prefix(2)))])
        let recovery = SettingsGroupView(title: "恢复提醒", subtitle: "剩余额度恢复到设定值并经后续查询确认后提醒，默认100%。", controls: [column(Array(rows.suffix(2)))])
        let stack = NSStackView(views: [low, recovery, rules, status, settings])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            low.widthAnchor.constraint(equalTo: stack.widthAnchor), recovery.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rules.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
        checks.forEach { $0.target = self; $0.action = #selector(changed) }
        settings.target = self; settings.action = #selector(openSettings)
        renderOptions()
    }
    private func renderOptions() {
        let options = preferences.usageAlertOptions
        let enabled = [options.fiveHourLow, options.weeklyLow, options.fiveHourRecovery, options.weeklyRecovery]
        let values = [options.lowThreshold(.fiveHour), options.lowThreshold(.weekly), options.recoveryThreshold(.fiveHour), options.recoveryThreshold(.weekly)]
        for index in 0..<4 {
            checks[index].state = enabled[index] ? .on : .off
            thresholds[index].update(values[index], enabled: enabled[index])
        }
    }
    func refresh() { renderOptions(); updatePermission() }
    @objc private func changed() {
        let enabled = checks.map { $0.state == .on }
        var options = preferences.usageAlertOptions
        options.fiveHourLow = enabled[0]; options.weeklyLow = enabled[1]
        options.fiveHourRecovery = enabled[2]; options.weeklyRecovery = enabled[3]
        preferences.usageAlertOptions = options
        renderOptions()
        Task { [weak self] in
            guard let self else { return }
            let result = self.preferences.usageAlertOptions.anyEnabled ? await self.service.requestIfNeeded() : await self.service.permission()
            self.renderPermission(result)
        }
    }
    private func setThreshold(_ value: Int, index: Int) {
        var options = preferences.usageAlertOptions
        switch index {
        case 0: options.fiveHourLowThreshold = value
        case 1: options.weeklyLowThreshold = value
        case 2: options.fiveHourRecoveryThreshold = value
        default: options.weeklyRecoveryThreshold = value
        }
        preferences.usageAlertOptions = options
    }
    private func updatePermission() {
        Task { [weak self] in
            guard let self else { return }; self.renderPermission(await self.service.permission())
        }
    }
    private func renderPermission(_ permission: UsageNotificationPermission) {
        switch permission {
        case .unknown: status.stringValue = "开启任一提醒时将申请通知权限。"
        case .allowed: status.stringValue = "系统通知权限已开启，设置自动保存。"
        case .denied: status.stringValue = "系统通知未允许，请在系统设置中开启 Codex TouchBar 通知。"
        }
        settings.isHidden = permission != .denied
    }
    @objc private func openSettings() { service.openSystemSettings() }
}
