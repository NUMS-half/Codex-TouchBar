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
    private let usedLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let progress = QuotaProgressView()
    private let kind: UsageWindowKind

    init(kind: UsageWindowKind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
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

        usedLabel.translatesAutoresizingMaskIntoConstraints = false
        usedLabel.font = .systemFont(ofSize: 11, weight: .regular)
        usedLabel.textColor = .secondaryLabelColor

        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .right

        progress.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, remainingLabel, usedLabel, resetLabel, progress].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 96),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            remainingLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            remainingLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            usedLabel.firstBaselineAnchor.constraint(equalTo: remainingLabel.firstBaselineAnchor),
            usedLabel.leadingAnchor.constraint(equalTo: remainingLabel.trailingAnchor, constant: 7),
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            resetLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            progress.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
    }

    func update(_ window: UsageWindow?) {
        guard let window else {
            remainingLabel.stringValue = "N/A"
            remainingLabel.textColor = .tertiaryLabelColor
            usedLabel.stringValue = "当前方案未提供"
            resetLabel.stringValue = ""
            progress.update(value: 0, tint: .tertiaryLabelColor)
            return
        }
        let remaining = window.remainingPercent
        remainingLabel.stringValue = "\(remaining)%"
        remainingLabel.textColor = statusColor(remainingPercent: remaining)
        usedLabel.stringValue = "已用 \(window.usedPercent)%"
        resetLabel.stringValue = "重置 \(formatResetDate(window.resetsAt))"
        progress.update(value: remaining, tint: statusColor(remainingPercent: remaining))
    }
}
