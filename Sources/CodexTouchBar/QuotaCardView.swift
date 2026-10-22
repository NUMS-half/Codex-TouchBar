import AppKit

private final class QuotaProgressView: NSView {
    private var value: Int = 0
    private var tint = NSColor.tertiaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func update(value: Int, tint: NSColor) {
        self.value = max(0, min(100, value))
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        NSColor.labelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let width = track.width * CGFloat(value) / 100
        guard width > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        tint.setFill()
        NSBezierPath(roundedRect: fill, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}

/// Reusable detail-panel card. The compact Touch Bar renderer lives separately
/// so panel typography can remain comfortably readable.
final class QuotaCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "—")
    private let remainingCaption = NSTextField(labelWithString: "剩余")
    private let resetLabel = NSTextField(labelWithString: "")
    private let changeLabel = NSTextField(labelWithString: "记录不足，暂不显示近期变化")
    private let progress = QuotaProgressView()
    private let kind: UsageWindowKind

    init(kind: UsageWindowKind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateSurface()
        setup()
        update(nil)
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = kind.accessibleTitle

        remainingLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 25, weight: .bold)
        remainingLabel.textColor = .labelColor

        remainingCaption.translatesAutoresizingMaskIntoConstraints = false
        remainingCaption.font = .systemFont(ofSize: 11, weight: .regular)
        remainingCaption.textColor = .secondaryLabelColor
        changeLabel.translatesAutoresizingMaskIntoConstraints = false
        changeLabel.font = .systemFont(ofSize: 11)
        changeLabel.textColor = .secondaryLabelColor
        changeLabel.lineBreakMode = .byTruncatingTail

        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .right

        progress.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, remainingLabel, remainingCaption, resetLabel, progress, changeLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 116),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            remainingLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            remainingLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            remainingCaption.firstBaselineAnchor.constraint(equalTo: remainingLabel.firstBaselineAnchor),
            remainingCaption.leadingAnchor.constraint(equalTo: remainingLabel.trailingAnchor, constant: 7),
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            resetLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.bottomAnchor.constraint(equalTo: changeLabel.topAnchor, constant: -8),
            progress.heightAnchor.constraint(equalToConstant: 6),
            changeLabel.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            changeLabel.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            changeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MenuPanelPalette.inset.cgColor
            layer?.borderColor = MenuPanelPalette.border.cgColor
        }
    }

    func update(_ window: UsageWindow?, hasSnapshot: Bool = false, change: UsageRecentChange? = nil, isStale: Bool = false, now: Date = Date()) {
        guard let window else {
            remainingLabel.stringValue = "—"
            remainingLabel.textColor = .tertiaryLabelColor
            remainingCaption.stringValue = hasSnapshot ? "未提供此窗口数据" : "尚未读取额度"
            changeLabel.stringValue = "暂无额度记录"
            changeLabel.toolTip = nil
            resetLabel.stringValue = ""
            resetLabel.toolTip = nil
            progress.update(value: 0, tint: .tertiaryLabelColor)
            return
        }
        let remaining = window.remainingPercent
        remainingLabel.stringValue = "\(remaining)%"
        remainingLabel.textColor = statusColor(remainingPercent: remaining)
        remainingCaption.stringValue = isStale ? "剩余 · 旧数据" : "剩余"
        resetLabel.stringValue = formatResetCountdown(window.resetsAt, now: now)
        resetLabel.toolTip = "重置时间：\(formatResetDate(window.resetsAt))"
        changeLabel.stringValue = isStale ? "旧数据，暂不显示近期变化" : change?.text ?? "记录不足，暂不显示近期变化"
        changeLabel.toolTip = changeLabel.stringValue
        progress.update(value: remaining, tint: statusColor(remainingPercent: remaining))
    }

}
