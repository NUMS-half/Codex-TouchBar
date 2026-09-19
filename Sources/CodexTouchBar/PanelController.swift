import AppKit
import ServiceManagement

private final class UsageDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let fiveHourCard = QuotaCardView(kind: .fiveHour)
    private let weeklyCard = QuotaCardView(kind: .weekly)
    private let titleLabel = NSTextField(labelWithString: "Codex 额度")
    private let planLabel = NSTextField(labelWithString: "")
    private let creditLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let freshnessLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let touchBarButton = NSButton(title: "Touch Bar：开", target: nil, action: nil)
    private let loginButton = NSButton(title: "登录启动：开", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private var panel: UsageDropdownPanel?
    private var closeOnResign = false

    var onRefresh: (() -> Void)?
    var onToggleTouchBar: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onQuit: (() -> Void)?

    private let panelSize = NSSize(width: 400, height: 392)

    override init() {
        super.init()
        configureControls()
    }

    private func configureControls() {
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        planLabel.font = .systemFont(ofSize: 11, weight: .medium)
        planLabel.textColor = .secondaryLabelColor
        creditLabel.font = .systemFont(ofSize: 11, weight: .regular)
        resetLabel.font = .systemFont(ofSize: 11, weight: .regular)
        [creditLabel, resetLabel].forEach { $0.textColor = .secondaryLabelColor }
        freshnessLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        freshnessLabel.textColor = .tertiaryLabelColor
        errorLabel.font = .systemFont(ofSize: 10, weight: .regular)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        touchBarButton.target = self
        touchBarButton.action = #selector(toggleTouchBar)
        loginButton.target = self
        loginButton.action = #selector(toggleLoginItem)
        quitButton.target = self
        quitButton.action = #selector(quit)
        [refreshButton, touchBarButton, loginButton, quitButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
        }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show(relativeTo positioningRect: NSRect, of view: NSView) {
        if isShown { close(); return }
        guard let screen = view.window?.screen ?? NSScreen.main else { return }

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, spacer(), planLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false

        let cards = NSStackView(views: [fiveHourCard, weeklyCard])
        cards.orientation = .vertical
        cards.spacing = 9
        cards.translatesAutoresizingMaskIntoConstraints = false

        let details = NSStackView(views: [creditLabel, resetLabel, freshnessLabel, errorLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3
        details.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [refreshButton, touchBarButton, loginButton, spacer(), quitButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        [header, cards, details, actions].forEach(backdrop.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 17),
            header.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -18),
            cards.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 15),
            cards.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            details.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 12),
            details.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -14),
        ])

        let panel = UsageDropdownPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = backdrop
        panel.delegate = self

        let buttonRect = view.window?.convertToScreen(view.convert(positioningRect, to: nil))
            ?? NSRect(x: screen.visibleFrame.maxX, y: screen.visibleFrame.maxY, width: 0, height: 0)
        var origin = NSPoint(x: buttonRect.maxX - panelSize.width, y: buttonRect.minY - panelSize.height - 6)
        origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - panelSize.width))
        if origin.y < screen.visibleFrame.minY { origin.y = buttonRect.maxY + 6 }
        panel.setFrameOrigin(origin)

        self.panel = panel
        closeOnResign = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        closeOnResign = false
        panel?.orderOut(nil)
        panel = nil
    }

    func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, error: String?, isRefreshing: Bool) {
        fiveHourCard.update(snapshot?.fiveHour)
        weeklyCard.update(snapshot?.weekly)
        let planParts = [snapshot?.planType, snapshot?.limitName].compactMap { $0 }.filter { !$0.isEmpty }
        planLabel.stringValue = planParts.joined(separator: " · ")
        creditLabel.stringValue = creditText(snapshot)
        resetLabel.stringValue = snapshot.map { "可用重置：\($0.availableResetCredits) 次" } ?? "可用重置：—"
        freshnessLabel.stringValue = freshnessText(snapshot, freshness)
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        refreshButton.title = isRefreshing ? "刷新中…" : "刷新"
        refreshButton.isEnabled = !isRefreshing
        touchBarButton.title = "Touch Bar：\(Preferences.shared.touchBarEnabled ? "开" : "关")"
        loginButton.title = "登录启动：\(SMAppService.mainApp.status == .enabled ? "开" : "关")"
    }

    private func creditText(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "积分：—" }
        if snapshot.unlimitedCredits { return "积分：不限额" }
        if let balance = snapshot.creditBalance { return "积分：\(balance)" }
        return "积分：暂无"
    }

    private func freshnessText(_ snapshot: UsageSnapshot?, _ freshness: SnapshotFreshness) -> String {
        guard let snapshot else { return "尚未读取额度" }
        switch freshness {
        case .live: return "在线 · \(formatUpdated(snapshot.fetchedAt))"
        case .cached: return "缓存 · \(formatUpdated(snapshot.fetchedAt))"
        case .stale: return "数据已过期 · \(formatUpdated(snapshot.fetchedAt))"
        }
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func refresh() { onRefresh?() }
    @objc private func toggleTouchBar() { onToggleTouchBar?() }
    @objc private func toggleLoginItem() { onToggleLoginItem?() }
    @objc private func quit() { onQuit?() }

    func windowDidBecomeKey(_ notification: Notification) { closeOnResign = true }
    func windowDidResignKey(_ notification: Notification) { if closeOnResign { close() } }
}
