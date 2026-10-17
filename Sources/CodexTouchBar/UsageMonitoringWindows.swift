import AppKit

private final class UsageWindowBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
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
    private let expiry = NSButton(checkboxWithTitle: "重置机会到期提醒（提前24小时）", target: nil, action: nil)
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
        let rules = NSTextField(wrappingLabelWithString: "阈值1%～100%，修改自动保存。低额和恢复提醒从下一次成功查询建立基线；恢复需后续查询确认。到期提醒按已确认的最近到期时间发送一次。关闭定时刷新后，提醒等待其他成功查询。")
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
        let stack = NSStackView(views: [low, recovery, expiry, rules, status, settings])
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
        expiry.target = self; expiry.action = #selector(changed)
        settings.target = self; settings.action = #selector(openSettings)
        renderOptions()
    }
    private func renderOptions() {
        let options = preferences.usageAlertOptions
        expiry.state = options.resetExpiry ? .on : .off
        let enabled = [options.fiveHourLow, options.weeklyLow, options.fiveHourRecovery, options.weeklyRecovery]
        let values = [options.lowThreshold(.fiveHour), options.lowThreshold(.weekly), options.recoveryThreshold(.fiveHour), options.recoveryThreshold(.weekly)]
        for index in 0..<4 {
            checks[index].state = enabled[index] ? .on : .off
            thresholds[index].update(values[index], enabled: enabled[index] || index >= 2)
        }
    }
    func refresh() { renderOptions(); updatePermission() }
    @objc private func changed() {
        let enabled = checks.map { $0.state == .on }
        var options = preferences.usageAlertOptions
        options.fiveHourLow = enabled[0]; options.weeklyLow = enabled[1]
        options.fiveHourRecovery = enabled[2]; options.weeklyRecovery = enabled[3]
        options.resetExpiry = expiry.state == .on
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
