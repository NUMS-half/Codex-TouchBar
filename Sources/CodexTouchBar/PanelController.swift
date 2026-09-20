import AppKit
import ServiceManagement

private final class PlanTagView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var displayedText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        guard !displayedText.isEmpty else { return .zero }
        let width = (displayedText as NSString).size(withAttributes: [.font: label.font!]).width
        return NSSize(width: ceil(width) + 18, height: 22)
    }

    func update(planType: String?, limitName: String?) {
        let parts = [planType.map(displayPlanName), limitName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueParts = parts.reduce(into: [String]()) { result, part in
            if !result.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                result.append(part)
            }
        }
        displayedText = uniqueParts.joined(separator: " · ")
        isHidden = displayedText.isEmpty
        label.stringValue = displayedText

        let colour = tagColor(for: displayedText)
        label.textColor = colour
        layer?.backgroundColor = colour.withAlphaComponent(0.16).cgColor
        invalidateIntrinsicContentSize()
    }

    private func displayPlanName(_ value: String) -> String {
        let words = value.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first else { return value }

        let canonicalNames = ["plus": "Plus", "free": "Free", "pro": "Pro"]
        guard let canonical = canonicalNames[String(first).lowercased()] else { return value }
        return ([canonical] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    private func tagColor(for text: String) -> NSColor {
        let value = text.lowercased()
        if value.contains("pro") { return .systemPurple }
        if value.contains("plus") { return .systemBlue }
        if value.contains("free") { return .secondaryLabelColor }
        if value.contains("team") || value.contains("business") { return .systemIndigo }
        return .controlAccentColor
    }
}

final class PanelController: NSObject, NSPopoverDelegate {
    private let fiveHourCard = QuotaCardView(kind: .fiveHour)
    private let weeklyCard = QuotaCardView(kind: .weekly)
    private let titleLabel = NSTextField(labelWithString: "Codex 额度")
    private let planTag = PlanTagView()
    private let creditLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let freshnessLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let refreshIntervalLabel = NSTextField(labelWithString: "自动刷新")
    private let refreshIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshIntervalHint = NSTextField(labelWithString: "仅 Codex 前台；后台固定 5 分钟")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let touchBarButton = NSButton(title: "Touch Bar：开", target: nil, action: nil)
    private let loginButton = NSButton(title: "登录启动：开", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    var onRefresh: (() -> Void)?
    var onToggleTouchBar: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onQuit: (() -> Void)?

    private let panelSize = NSSize(width: 360, height: 426)

    override init() {
        super.init()
        configureControls()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func configureControls() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        [creditLabel, resetLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }
        freshnessLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        freshnessLabel.textColor = .tertiaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail

        refreshIntervalLabel.font = .systemFont(ofSize: 12, weight: .medium)
        refreshIntervalLabel.textColor = .secondaryLabelColor
        refreshIntervalHint.font = .systemFont(ofSize: 10, weight: .regular)
        refreshIntervalHint.textColor = .tertiaryLabelColor
        refreshIntervalPopup.controlSize = .small
        refreshIntervalPopup.target = self
        refreshIntervalPopup.action = #selector(changeRefreshInterval)
        Preferences.refreshIntervals.forEach { interval in
            refreshIntervalPopup.addItem(withTitle: Preferences.refreshIntervalTitle(interval))
            refreshIntervalPopup.lastItem?.tag = Int(interval)
        }

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

    var isShown: Bool { popover.isShown }

    func show(relativeTo positioningRect: NSRect, of view: NSView) {
        if isShown { close(); return }

        // NSPopover owns the native material, corner radius, and shadow.  The
        // content view only supplies the panel's layout, so it never needs to
        // simulate a window with a transparent borderless NSPanel.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, spacer(), planTag])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        let cards = NSStackView(views: [fiveHourCard, weeklyCard])
        cards.orientation = .vertical
        cards.spacing = 8
        cards.translatesAutoresizingMaskIntoConstraints = false

        let details = NSStackView(views: [creditLabel, resetLabel, freshnessLabel, errorLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        details.translatesAutoresizingMaskIntoConstraints = false

        let refreshSettings = NSStackView(views: [refreshIntervalLabel, refreshIntervalPopup, spacer(), refreshIntervalHint])
        refreshSettings.orientation = .horizontal
        refreshSettings.alignment = .centerY
        refreshSettings.spacing = 7
        refreshSettings.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [refreshButton, touchBarButton, loginButton, spacer(), quitButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        [header, cards, details, refreshSettings, actions].forEach(backdrop.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            cards.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            cards.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            details.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 11),
            details.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            refreshSettings.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 10),
            refreshSettings.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            refreshSettings.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.topAnchor.constraint(greaterThanOrEqualTo: refreshSettings.bottomAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -13),
        ])

        let controller = NSViewController()
        controller.view = backdrop
        popover.contentViewController = controller
        popover.contentSize = panelSize
        popover.show(relativeTo: positioningRect, of: view, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    func close() {
        removeOutsideClickMonitor()
        popover.performClose(nil)
    }

    func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, error: String?, isRefreshing: Bool) {
        fiveHourCard.update(snapshot?.fiveHour)
        weeklyCard.update(snapshot?.weekly)
        planTag.update(planType: snapshot?.planType, limitName: snapshot?.limitName)
        creditLabel.stringValue = creditText(snapshot)
        resetLabel.stringValue = snapshot.map { "可用重置：\($0.availableResetCredits) 次" } ?? "可用重置：—"
        freshnessLabel.stringValue = freshnessText(snapshot, freshness)
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        refreshIntervalPopup.selectItem(withTag: Int(Preferences.shared.refreshInterval))
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
    @objc private func changeRefreshInterval() {
        Preferences.shared.refreshInterval = TimeInterval(refreshIntervalPopup.selectedTag())
    }
    @objc private func toggleTouchBar() { onToggleTouchBar?() }
    @objc private func toggleLoginItem() { onToggleLoginItem?() }
    @objc private func quit() { onQuit?() }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}
