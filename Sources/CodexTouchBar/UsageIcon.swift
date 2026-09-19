import AppKit

/// A small, monochrome rendering of the app icon for the menu bar. Keeping it
/// template-based lets macOS supply the correct colour in light and dark menus.
enum UsageIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()

        let outer = NSRect(x: 0.75, y: 3, width: 14.5, height: 10)
        NSColor.black.setStroke()
        let shell = NSBezierPath(roundedRect: outer, xRadius: 3, yRadius: 3)
        shell.lineWidth = 1.4
        shell.stroke()

        let inset: CGFloat = 2.6
        let gap: CGFloat = 1.5
        let barWidth = (outer.width - inset * 2 - gap) / 2
        let left = NSRect(x: outer.minX + inset, y: outer.minY + 2.4, width: barWidth, height: 2.2)
        let right = NSRect(x: left.maxX + gap, y: outer.minY + 2.4, width: barWidth, height: 2.2)
        NSBezierPath(roundedRect: left, xRadius: 1.1, yRadius: 1.1).fill()
        NSBezierPath(roundedRect: right, xRadius: 1.1, yRadius: 1.1).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

/// A compact two-line status readout. It avoids the wide, single-line menu-bar
/// title while retaining both quota windows at a glance.
final class StatusUsageReadoutView: NSView {
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let valueColumnWidth = ceil(
        ("100%" as NSString).size(withAttributes: [.font: valueFont]).width
    )
    private static let preferredWidth: CGFloat = 15 + 5 + 14 + 2 + valueColumnWidth

    /// Includes one point of system-button margin on each side.
    static let menuItemWidth = preferredWidth + 2

    private let iconView = NSImageView(image: UsageIcon.menuBarImage())
    private let fiveHourNameLabel = NSTextField(labelWithString: "5H")
    private let weeklyNameLabel = NSTextField(labelWithString: "周")
    private let fiveHourValueLabel = NSTextField(labelWithString: "—")
    private let weeklyValueLabel = NSTextField(labelWithString: "—")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        [fiveHourNameLabel, weeklyNameLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.lineBreakMode = .byClipping
        }
        [fiveHourValueLabel, weeklyValueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.font = Self.valueFont
            // A fixed column is needed for 100%, but values must end at its
            // trailing edge so shorter values do not leave a visible right gap.
            $0.alignment = .right
            $0.lineBreakMode = .byClipping
        }

        addSubview(iconView)
        addSubview(fiveHourNameLabel)
        addSubview(weeklyNameLabel)
        addSubview(fiveHourValueLabel)
        addSubview(weeklyValueLabel)
        NSLayoutConstraint.activate([
            // 100% is the widest value. The value column is measured from the
            // actual menu-bar font rather than reserving a visually empty area.
            widthAnchor.constraint(equalToConstant: Self.preferredWidth),
            heightAnchor.constraint(equalToConstant: 20),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            fiveHourNameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            fiveHourNameLabel.widthAnchor.constraint(equalToConstant: 14),
            fiveHourNameLabel.topAnchor.constraint(equalTo: topAnchor),
            weeklyNameLabel.leadingAnchor.constraint(equalTo: fiveHourNameLabel.leadingAnchor),
            weeklyNameLabel.widthAnchor.constraint(equalTo: fiveHourNameLabel.widthAnchor),
            weeklyNameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            fiveHourValueLabel.leadingAnchor.constraint(equalTo: fiveHourNameLabel.trailingAnchor, constant: 2),
            fiveHourValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            fiveHourValueLabel.topAnchor.constraint(equalTo: topAnchor),
            weeklyValueLabel.leadingAnchor.constraint(equalTo: fiveHourValueLabel.leadingAnchor),
            weeklyValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            weeklyValueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // The containing NSStatusBarButton remains responsible for left and right
    // clicks; labels are visual only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(fiveHour: UsageWindow?, weekly: UsageWindow?) {
        update(valueLabel: fiveHourValueLabel, window: fiveHour)
        update(valueLabel: weeklyValueLabel, window: weekly)
    }

    private func update(valueLabel: NSTextField, window: UsageWindow?) {
        valueLabel.stringValue = window.map { "\($0.remainingPercent)%" } ?? "—"
        valueLabel.textColor = window.map { statusColor(remainingPercent: $0.remainingPercent) } ?? .tertiaryLabelColor
    }
}
