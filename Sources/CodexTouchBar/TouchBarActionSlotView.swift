import AppKit

/// Shared by the physical Touch Bar and its non-interactive settings preview.
final class TouchBarActionSlotView: NSView {
    private let commandButton = NSButton(title: "", target: nil, action: nil)
    private let backButton = NSButton(title: "←", target: nil, action: nil)
    private let forwardButton = NSButton(title: "→", target: nil, action: nil)
    private(set) var configuration = TouchBarConfiguration.defaultSlots[0]
    var onAction: ((DesktopCommand) -> Void)?
    var isPreview = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure(commandButton, fontSize: 12, action: #selector(commandTapped))
        configure(backButton, fontSize: 17, action: #selector(backTapped))
        configure(forwardButton, fontSize: 17, action: #selector(forwardTapped))
        backButton.setAccessibilityLabel("后退")
        forwardButton.setAccessibilityLabel("前进")
        update(configuration)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { isPreview ? nil : super.hitTest(point) }

    override func layout() {
        super.layout()
        commandButton.frame = bounds
        backButton.frame = NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        forwardButton.frame = NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
    }

    func update(_ configuration: TouchBarSlotConfiguration) {
        self.configuration = configuration.normalized
        let isNavigation = configuration.action == .navigationPair
        commandButton.isHidden = isNavigation
        backButton.isHidden = !isNavigation
        forwardButton.isHidden = !isNavigation
        commandButton.title = self.configuration.buttonTitle
        commandButton.setAccessibilityLabel(self.configuration.buttonTitle)
        toolTip = configuration.action.displayName
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if configuration.action == .navigationPair {
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(rect: NSRect(x: bounds.midX - 0.5, y: 5, width: 1, height: bounds.height - 10)).fill()
        }
    }

    private func configure(_ button: NSButton, fontSize: CGFloat, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: fontSize, weight: fontSize == 12 ? .semibold : .medium)
        // Touch Bar controls always have a dark background, including when
        // their settings preview is embedded in a light macOS window.
        button.contentTintColor = .white
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false
        addSubview(button)
    }

    @objc private func commandTapped() {
        guard !isPreview, case let .command(command) = configuration.action else { return }
        onAction?(command)
    }
    @objc private func backTapped() { if !isPreview { onAction?(.builtIn(.back)) } }
    @objc private func forwardTapped() { if !isPreview { onAction?(.builtIn(.forward)) } }
}
