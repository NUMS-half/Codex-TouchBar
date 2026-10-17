import AppKit

@MainActor
final class UsageHistoryViewController: NSViewController {
    static let panelSize = NSSize(width: 620, height: 460)
    private let monitor: UsageMonitoringController
    private let snapshot: () -> UsageSnapshot?
    private let isStale: () -> Bool
    private let chart = UsageChartView(frame: .zero)
    private let selector = NSSegmentedControl(labels: ["5H", "周 · 10天"], trackingMode: .selectOne, target: nil, action: nil)
    private let rangeSelector = NSSegmentedControl(labels: UsageChartRange.fiveHourOptions.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private var fiveHourRange = UsageChartRange.sixHours
    private let chartCaption = NSTextField(labelWithString: "")
    private let legend = UsageChartLegendView(frame: .zero)
    private let balanceCaption = NSTextField(labelWithString: "剩余额度")
    private let balanceLabel = NSTextField(labelWithString: "—")
    private let updatedLabel = NSTextField(labelWithString: "正在读取记录…")
    private let firstLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: "清空历史记录…", target: nil, action: nil)
    private var kind = UsageWindowKind.fiveHour
    private var readTask: Task<Void, Never>?
    private var generation = 0
    private var active = false
    var onBack: (() -> Void)?
    private let backButton = NSButton(title: "返回", target: nil, action: nil)
    private let cancelClearButton = NSButton(title: "取消", target: nil, action: nil)
    private var confirmingClear = false

    init(monitor: UsageMonitoringController, snapshot: @escaping () -> UsageSnapshot?, isStale: @escaping () -> Bool = { false }) {
        self.monitor = monitor; self.snapshot = snapshot; self.isStale = isStale
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let root = view
        backButton.target = self; backButton.action = #selector(goBack)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading; backButton.bezelStyle = .rounded; backButton.controlSize = .small
        backButton.setAccessibilityLabel("返回额度概览")
        let title = NSTextField(labelWithString: "额度变化")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let navigationGap = NSView(); navigationGap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let navigation = NSStackView(views: [backButton, title, navigationGap, selector])
        navigation.orientation = .horizontal; navigation.alignment = .centerY; navigation.spacing = 12
        selector.selectedSegment = 0; selector.target = self; selector.action = #selector(selectKind)
        selector.font = .systemFont(ofSize: 12, weight: .medium)
        selector.segmentStyle = .rounded
        selector.setAccessibilityLabel("额度类型")
        rangeSelector.selectedSegment = 0; rangeSelector.target = self; rangeSelector.action = #selector(selectRange)
        rangeSelector.segmentStyle = .rounded; rangeSelector.controlSize = .small
        rangeSelector.setAccessibilityLabel("5H显示范围")
        chartCaption.font = .systemFont(ofSize: 11); chartCaption.textColor = UsageChartPalette.muted
        chartCaption.stringValue = fiveHourRange.caption
        chartCaption.toolTip = "同周期下降区间可估计；跨刷新空档沿用此前末值，到后续实测时跳变，不推测刷新时刻或补造100%。淡色柱均为非实测，不参与提醒。"
        let rangeGap = NSView(); rangeGap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rangeRow = NSStackView(views: [chartCaption, rangeGap, rangeSelector])
        rangeRow.orientation = .horizontal; rangeRow.alignment = .centerY; rangeRow.spacing = 12
        clearButton.target = self; clearButton.action = #selector(clearHistory)
        clearButton.bezelStyle = .rounded; clearButton.font = .systemFont(ofSize: 12)
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearButton.imagePosition = .imageLeading; clearButton.contentTintColor = UsageChartPalette.muted
        clearButton.toolTip = "清空5H和周额度历史，需要确认"
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        balanceCaption.font = .systemFont(ofSize: 12); balanceCaption.textColor = UsageChartPalette.muted
        balanceLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        updatedLabel.font = .systemFont(ofSize: 11); updatedLabel.textColor = UsageChartPalette.muted
        firstLabel.font = .systemFont(ofSize: 11); firstLabel.textColor = UsageChartPalette.muted
        firstLabel.lineBreakMode = .byTruncatingTail
        firstLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11); status.textColor = UsageChartPalette.muted
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let balance = NSStackView(views: [balanceCaption, balanceLabel])
        balance.orientation = .horizontal; balance.alignment = .lastBaseline; balance.spacing = 10
        let gap = NSView(); gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [balance, gap])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12
        let dates = NSStackView(views: [updatedLabel, firstLabel])
        dates.orientation = .horizontal; dates.alignment = .lastBaseline; dates.spacing = 24
        let hint = NSTextField(labelWithString: "悬停查看查询详情")
        hint.font = .systemFont(ofSize: 11); hint.textColor = UsageChartPalette.muted
        let legendGap = NSView(); legendGap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let legendRow = NSStackView(views: [legend, legendGap, hint])
        legendRow.orientation = .horizontal; legendRow.alignment = .centerY
        let footerGap = NSView(); footerGap.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        cancelClearButton.target = self; cancelClearButton.action = #selector(cancelClear)
        cancelClearButton.bezelStyle = .rounded; cancelClearButton.controlSize = .small; cancelClearButton.isHidden = true
        let footer = NSStackView(views: [status, footerGap, clearButton, cancelClearButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 16; footer.distribution = .fill
        for view in [navigation, header, dates, rangeRow, chart, legendRow, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            navigation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            dates.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            dates.leadingAnchor.constraint(equalTo: header.leadingAnchor), dates.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            rangeRow.topAnchor.constraint(equalTo: dates.bottomAnchor, constant: 12),
            rangeRow.leadingAnchor.constraint(equalTo: header.leadingAnchor), rangeRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            chart.topAnchor.constraint(equalTo: rangeRow.bottomAnchor, constant: 8), chart.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: header.trailingAnchor), chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            legendRow.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 8), legendRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            legendRow.trailingAnchor.constraint(equalTo: header.trailingAnchor), legend.heightAnchor.constraint(equalToConstant: 18),
            footer.topAnchor.constraint(equalTo: legendRow.bottomAnchor, constant: 8), footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            clearButton.widthAnchor.constraint(equalToConstant: 146), clearButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func activate(kind requested: UsageWindowKind? = nil) {
        if let requested { kind = requested }
        if chart.kind != kind { display(.init(points: [], notice: nil), kind: kind, now: Date()) }
        selector.selectedSegment = kind == .fiveHour ? 0 : 1
        active = true
        reload()
    }
    func deactivate() {
        active = false; generation += 1; readTask?.cancel(); cancelClear()
    }
    @objc private func goBack() { onBack?() }
    func waitForPendingRead() async { await readTask?.value }

    func reload() {
        guard active else { return }
        generation += 1; let ticket = generation; let selected = kind; let now = Date()
        readTask?.cancel()
        readTask = Task { [weak self, monitor] in
            do {
                let result = try await monitor.history.read(selected, now: now)
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.display(result, kind: selected, now: now)
            } catch {
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                if self.chart.kind != selected {
                    self.display(.init(points: [], notice: nil), kind: selected, now: now)
                }
                self.status.stringValue = "读取失败，稍后重新打开图表重试；已有额度不受影响。"
                self.status.textColor = .systemOrange
            }
        }
    }
    func display(_ result: UsageHistoryResult, kind selected: UsageWindowKind, now: Date) {
        kind = selected; selector.selectedSegment = selected == .fiveHour ? 0 : 1
        chart.kind = selected; chart.end = now; chart.points = result.points
        updateRange()
        let value = snapshot()
        let windowValue = selected == .fiveHour ? value?.fiveHour : value?.weekly
        let latest = result.points.last
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm:ss"
        let remaining = windowValue?.remainingPercent ?? latest?.remaining
        let balance = remaining.map { "\($0)%" } ?? "—"
        balanceCaption.stringValue = windowValue == nil && latest != nil ? "最近记录" : "剩余额度"
        balanceLabel.stringValue = balance
        balanceLabel.textColor = remaining.map(UsageChartPalette.quota) ?? UsageChartPalette.muted
        updatedLabel.stringValue = "最近查询  " + (latest.map { formatter.string(from: $0.time) } ?? "—")
        formatter.dateFormat = "MM/dd HH:mm"
        firstLabel.stringValue = "记录始于  " + (result.points.first.map { formatter.string(from: $0.time) } ?? "—")
        chart.setAccessibilityValue("\(selected.accessibleTitle)，余额 \(balance)")
        let stale = isStale() || (latest.map { now.timeIntervalSince($0.time) > 900 } ?? false)
        status.stringValue = confirmingClear ? "清空5H和周额度历史？" : monitor.historyError ?? result.notice
            ?? (stale ? "最近查询尚未更新，当前显示已有记录。" : "记录仅保存在本机，超期自动清理。")
        status.textColor = monitor.historyError != nil || result.notice != nil ? .systemOrange : UsageChartPalette.muted
    }
    @objc private func selectKind() {
        kind = selector.selectedSegment == 0 ? .fiveHour : .weekly
        display(.init(points: [], notice: nil), kind: kind, now: Date())
        reload()
    }
    private func updateRange() {
        chart.range = kind == .fiveHour ? fiveHourRange : .tenDays
        chartCaption.stringValue = chart.range.caption
        rangeSelector.isHidden = kind != .fiveHour
        rangeSelector.selectedSegment = UsageChartRange.fiveHourOptions.firstIndex(of: fiveHourRange) ?? 0
        chart.setAccessibilityLabel("\(kind.accessibleTitle)，\(chart.range.title)，\(chart.range.caption)。跨刷新沿用前值，非实测不参与提醒。")
    }
    @objc private func selectRange() {
        guard kind == .fiveHour, UsageChartRange.fiveHourOptions.indices.contains(rangeSelector.selectedSegment) else { return }
        fiveHourRange = UsageChartRange.fiveHourOptions[rangeSelector.selectedSegment]
        updateRange()
    }
    @objc private func clearHistory() {
        guard confirmingClear else {
            confirmingClear = true; clearButton.title = "确认清空"; cancelClearButton.isHidden = false
            status.stringValue = "清空5H和周额度历史？"
            return
        }
        clearButton.isEnabled = false; cancelClearButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.monitor.clearHistory()
            self.clearButton.isEnabled = true; self.cancelClearButton.isEnabled = true
            self.cancelClear()
        }
    }
    @objc private func cancelClear() {
        confirmingClear = false; clearButton.title = "清空历史记录…"; cancelClearButton.isHidden = true
        if active { reload() }
    }
}
