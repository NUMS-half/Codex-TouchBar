import AppKit

/// Compact aligned rows; all text uses the standard macOS system font. Widths
/// follow the widest currently displayed row, without six-digit reservations.
final class StatusUsageReadoutView: NSView {
    private static let textFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static func textWidth(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: textFont]).width) }
    private static let nameWidth = max(textWidth("H"), textWidth("W"))
    private static let quotaGap: CGFloat = 2
    private static let dividerGap: CGFloat = 5
    private static let initialValueWidth = textWidth("—")
    private static let initialRateWidth = max(textWidth("⚡️—"), textWidth("tok/s"))
    // Ordinary system digits are proportional. Reserve only this digit count,
    // so 11 -> 88 is stable without reserving six digits for a two-digit rate.
    private static let rateDigitWidths: [CGFloat] = (1...6).map { count in
        (0...9).map { textWidth("⚡️" + String(repeating: String($0), count: count)) }.max() ?? 0
    }
    private static func rateWidth(_ digits: String) -> CGFloat {
        let actual = textWidth("⚡️" + digits)
        guard (1...6).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return actual }
        return max(actual, rateDigitWidths[digits.count - 1])
    }
    static let menuItemWidth = nameWidth + quotaGap + initialValueWidth + 2

    private let fiveHourNameLabel = NSTextField(labelWithString: "H")
    private let weeklyNameLabel = NSTextField(labelWithString: "W")
    private let fiveHourValueLabel = NSTextField(labelWithString: "—")
    private let weeklyValueLabel = NSTextField(labelWithString: "—")
    private let rateLabel = NSTextField(labelWithString: "⚡️—")
    private let unitLabel = NSTextField(labelWithString: "tok/s")
    private let divider = NSView()
    private var widthConstraint: NSLayoutConstraint!
    private var rateWidthConstraint: NSLayoutConstraint!
    private var quotaLeading: NSLayoutConstraint!
    private var valueColumnWidth = StatusUsageReadoutView.initialValueWidth
    private var rateColumnWidth = StatusUsageReadoutView.initialRateWidth
    private(set) var showsTPS = false
    private var quotaWidth: CGFloat { Self.nameWidth + Self.quotaGap + valueColumnWidth }
    private var speedWidth: CGFloat { rateColumnWidth + Self.dividerGap * 2 + 1 }
    var menuItemWidth: CGFloat { quotaWidth + (showsTPS ? speedWidth : 0) + 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for label in [fiveHourNameLabel, weeklyNameLabel, fiveHourValueLabel, weeklyValueLabel, rateLabel, unitLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Self.textFont
            label.alignment = .right
            label.lineBreakMode = .byClipping
            addSubview(label)
        }
        rateLabel.setAccessibilityIdentifier("sessionTPS.menuBar.rate")
        unitLabel.setAccessibilityIdentifier("sessionTPS.menuBar.unit")
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true; addSubview(divider)
        widthConstraint = widthAnchor.constraint(equalToConstant: quotaWidth)
        rateWidthConstraint = rateLabel.widthAnchor.constraint(equalToConstant: rateColumnWidth)
        quotaLeading = fiveHourNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            widthConstraint, heightAnchor.constraint(equalToConstant: 20),
            rateLabel.leadingAnchor.constraint(equalTo: leadingAnchor), rateWidthConstraint,
            rateLabel.topAnchor.constraint(equalTo: topAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: rateLabel.leadingAnchor),
            unitLabel.widthAnchor.constraint(equalTo: rateLabel.widthAnchor),
            unitLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: rateLabel.trailingAnchor, constant: Self.dividerGap),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            quotaLeading,
            fiveHourNameLabel.widthAnchor.constraint(equalToConstant: Self.nameWidth),
            fiveHourNameLabel.topAnchor.constraint(equalTo: topAnchor),
            weeklyNameLabel.leadingAnchor.constraint(equalTo: fiveHourNameLabel.leadingAnchor),
            weeklyNameLabel.widthAnchor.constraint(equalTo: fiveHourNameLabel.widthAnchor),
            weeklyNameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            fiveHourValueLabel.leadingAnchor.constraint(equalTo: fiveHourNameLabel.trailingAnchor, constant: Self.quotaGap),
            fiveHourValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            fiveHourValueLabel.topAnchor.constraint(equalTo: topAnchor),
            weeklyValueLabel.leadingAnchor.constraint(equalTo: fiveHourValueLabel.leadingAnchor),
            weeklyValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            weeklyValueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rateLabel.isHidden = true; unitLabel.isHidden = true; divider.isHidden = true
        updateAppearanceColors()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearanceColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAppearanceColors() }
    private func updateAppearanceColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = NSColor(srgbRed: dark ? 0.88 : 0.12, green: dark ? 0.88 : 0.12, blue: dark ? 0.88 : 0.12, alpha: 1)
        [fiveHourNameLabel, weeklyNameLabel, rateLabel, unitLabel].forEach { $0.textColor = color }
        divider.layer?.backgroundColor = color.withAlphaComponent(0.35).cgColor
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func updateColumnWidths() {
        let leading = showsTPS ? speedWidth : 0
        if quotaLeading.constant != leading { quotaLeading.constant = leading }
        if rateWidthConstraint.constant != rateColumnWidth { rateWidthConstraint.constant = rateColumnWidth }
        let width = menuItemWidth - 2
        if widthConstraint.constant != width { widthConstraint.constant = width }
    }
    func update(fiveHour: UsageWindow?, weekly: UsageWindow?) {
        update(valueLabel: fiveHourValueLabel, window: fiveHour)
        update(valueLabel: weeklyValueLabel, window: weekly)
        valueColumnWidth = max(Self.textWidth(fiveHourValueLabel.stringValue), Self.textWidth(weeklyValueLabel.stringValue))
        updateColumnWidths()
    }
    func updateSessionTPS(_ snapshot: SessionTPSSnapshot, enabled: Bool) {
        if showsTPS != enabled {
            showsTPS = enabled
            rateLabel.isHidden = !enabled; unitLabel.isHidden = !enabled; divider.isHidden = !enabled
        }
        let text = "⚡️" + snapshot.rateText
        if rateLabel.stringValue != text { rateLabel.stringValue = text }
        rateColumnWidth = max(Self.rateWidth(snapshot.rateText), Self.textWidth(unitLabel.stringValue))
        updateColumnWidths()
        if rateLabel.toolTip != snapshot.toolTip { rateLabel.toolTip = snapshot.toolTip; unitLabel.toolTip = snapshot.toolTip }
        let accessibility = "当前对话输出速度：" + snapshot.displayText
        if rateLabel.accessibilityLabel() != accessibility { rateLabel.setAccessibilityLabel(accessibility) }
    }
    private func update(valueLabel: NSTextField, window: UsageWindow?) {
        let text = window.map { "\($0.remainingPercent)%" } ?? "—"
        if valueLabel.stringValue != text { valueLabel.stringValue = text }
        valueLabel.textColor = window.map { statusColor(remainingPercent: $0.remainingPercent) } ?? .tertiaryLabelColor
    }
}
