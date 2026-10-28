import AppKit

/// Shared by the physical Touch Bar and its non-interactive settings preview.
final class TouchBarActionSlotView: NSView {
    private let commandButton = NSButton(title: "", target: nil, action: nil)
    private let backButton = NSButton(title: "←", target: nil, action: nil)
    private let forwardButton = NSButton(title: "→", target: nil, action: nil)
    private(set) var configuration = TouchBarConfiguration.defaultSlots[0]
    var onAction: ((DesktopCommand) -> Void)?
    var isPreview = false
    private var sessionTPS: SessionTPSSnapshot?

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

    override func hitTest(_ point: NSPoint) -> NSView? { (isPreview || configuration.action == .sessionTPS) ? nil : super.hitTest(point) }

    override func layout() {
        super.layout()
        commandButton.frame = bounds
        fitReadoutFont()
        backButton.frame = NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        forwardButton.frame = NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
    }

    func update(_ configuration: TouchBarSlotConfiguration) {
        self.configuration = configuration.normalized
        let isNavigation = configuration.action == .navigationPair
        commandButton.isHidden = isNavigation
        backButton.isHidden = !isNavigation
        forwardButton.isHidden = !isNavigation
        commandButton.title = self.configuration.action == .sessionTPS ? (sessionTPS?.displayText ?? "⚡ — tok/s") : self.configuration.buttonTitle
        commandButton.font = .systemFont(ofSize: self.configuration.action == .sessionTPS ? 10 : 12, weight: .semibold)
        commandButton.setAccessibilityLabel(commandButton.title)
        commandButton.setAccessibilityRole(self.configuration.action == .sessionTPS ? .staticText : .button)
        toolTip = configuration.action.displayName
        fitReadoutFont()
        needsLayout = true
        needsDisplay = true
    }

    func updateSessionTPS(_ snapshot: SessionTPSSnapshot?) {
        guard sessionTPS != snapshot else { return }
        sessionTPS = snapshot
        guard configuration.action == .sessionTPS else { return }
        let text = snapshot?.displayText ?? "⚡ — tok/s"
        if commandButton.title != text {
            commandButton.title = text
            commandButton.setAccessibilityLabel(text)
            fitReadoutFont()
            needsLayout = true; needsDisplay = true
        }
        toolTip = snapshot?.toolTip ?? "当前对话输出速度；仅显示，点击无操作"
    }

    private func fitReadoutFont() {
        guard configuration.action == .sessionTPS, bounds.width > 8 else { return }
        var size: CGFloat = 10
        while size > 7 && (commandButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width > bounds.width - 6 { size -= 0.5 }
        commandButton.font = .systemFont(ofSize: size, weight: .semibold)
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
