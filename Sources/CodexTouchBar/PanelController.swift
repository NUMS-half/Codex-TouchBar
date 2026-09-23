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
    private let creditIcon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: "积分") ?? NSImage())
    private let creditLabel = NSTextField(labelWithString: "")
    private let resetIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: "可用重置") ?? NSImage())
    private let resetLabel = NSTextField(labelWithString: "")
    private let resetExpiryLabel = NSTextField(labelWithString: "")
    private let freshnessLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let errorDetailsButton = NSButton(title: "查看详情", target: nil, action: nil)
    private let errorCopyButton = NSButton(title: "复制", target: nil, action: nil)
    private let errorDetailsPopover = NSPopover()
    private var errorBannerView: NSStackView?
    private var currentErrorMessage: String?
    private let refreshIntervalLabel = NSTextField(labelWithString: "自动刷新")
    private let refreshIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshIntervalHint = NSTextField(labelWithString: "Codex 前台；后台 5 分钟")
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

    private let panelSize = NSSize(width: 340, height: 370)

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
        [creditIcon, resetIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            $0.contentTintColor = .secondaryLabelColor
            $0.imageScaling = .scaleProportionallyDown
            NSLayoutConstraint.activate([
                $0.widthAnchor.constraint(equalToConstant: 14),
                $0.heightAnchor.constraint(equalToConstant: 14),
            ])
        }
        freshnessLabel.textColor = .tertiaryLabelColor
        freshnessLabel.font = .systemFont(ofSize: 11, weight: .regular)
        freshnessLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 2
        errorLabel.usesSingleLineMode = false
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetExpiryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        resetExpiryLabel.textColor = .tertiaryLabelColor
        resetExpiryLabel.lineBreakMode = .byTruncatingTail
        resetExpiryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        errorDetailsButton.isBordered = false
        errorDetailsButton.font = .systemFont(ofSize: 11, weight: .medium)
        errorDetailsButton.contentTintColor = .controlAccentColor
        errorDetailsButton.target = self
        errorDetailsButton.action = #selector(showErrorDetails)
        errorCopyButton.target = self
        errorCopyButton.action = #selector(copyErrorDetails)
        errorDetailsPopover.behavior = .transient
        errorDetailsPopover.animates = true

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
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        backdrop.material = .popover
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let titleAndStatus = NSStackView(views: [titleLabel, freshnessLabel])
        titleAndStatus.orientation = .horizontal
        titleAndStatus.alignment = .lastBaseline
        titleAndStatus.spacing = 8
        titleAndStatus.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleAndStatus, spacer(), planTag])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        let cards = NSStackView(views: [fiveHourCard, weeklyCard])
        cards.orientation = .vertical
        cards.spacing = 8
        cards.translatesAutoresizingMaskIntoConstraints = false

        let creditRow = NSStackView(views: [creditIcon, creditLabel])
        creditRow.orientation = .horizontal
        creditRow.alignment = .centerY
        creditRow.spacing = 6
        creditRow.translatesAutoresizingMaskIntoConstraints = false

        let resetRow = NSStackView(views: [resetIcon, resetLabel, spacer(), resetExpiryLabel])
        resetRow.orientation = .horizontal
        resetRow.alignment = .centerY
        resetRow.spacing = 6
        resetRow.translatesAutoresizingMaskIntoConstraints = false

        let errorBanner = NSStackView(views: [errorLabel, errorDetailsButton])
        errorBanner.orientation = .horizontal
        errorBanner.alignment = .centerY
        errorBanner.spacing = 6
        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: panelSize.width - 100).isActive = true
        errorBanner.isHidden = currentErrorMessage == nil
        errorBannerView = errorBanner

        let details = NSStackView(views: [creditRow, resetRow])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        details.translatesAutoresizingMaskIntoConstraints = false

        refreshIntervalHint.isHidden = currentErrorMessage != nil
        let refreshSettings = NSStackView(views: [refreshIntervalLabel, refreshIntervalPopup, spacer(), refreshIntervalHint, errorBanner])
        refreshSettings.orientation = .horizontal
        refreshSettings.alignment = .centerY
        refreshSettings.spacing = 7
        refreshSettings.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [refreshButton, touchBarButton, loginButton, spacer(), quitButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 3
        actions.translatesAutoresizingMaskIntoConstraints = false

        [header, cards, details, refreshSettings, actions].forEach(backdrop.addSubview)
        NSLayoutConstraint.activate([
            backdrop.widthAnchor.constraint(equalToConstant: panelSize.width),
            backdrop.heightAnchor.constraint(equalToConstant: panelSize.height),
            header.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            cards.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            cards.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            details.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 11),
            details.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            resetRow.widthAnchor.constraint(equalTo: details.widthAnchor),
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
        controller.preferredContentSize = panelSize
        popover.contentViewController = controller
        popover.contentSize = panelSize
        popover.show(relativeTo: positioningRect, of: view, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    func close() {
        removeOutsideClickMonitor()
        if errorDetailsPopover.isShown { errorDetailsPopover.performClose(nil) }
        popover.performClose(nil)
    }

    func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, error: String?, isRefreshing: Bool) {
        fiveHourCard.update(snapshot?.fiveHour)
        weeklyCard.update(snapshot?.weekly)
        planTag.update(planType: snapshot?.planType, limitName: snapshot?.limitName)
        creditLabel.stringValue = creditText(snapshot)
        resetLabel.stringValue = snapshot.map { "可用重置：\($0.availableResetCredits) 次" } ?? "可用重置：—"
        let expiry = snapshot?.earliestAvailableResetExpiry.flatMap { $0 > Date() ? $0 : nil }
        resetExpiryLabel.stringValue = expiry.map(resetExpiryText) ?? ""
        resetExpiryLabel.isHidden = expiry == nil
        freshnessLabel.stringValue = freshnessText(snapshot, freshness)
        currentErrorMessage = error
        errorLabel.stringValue = error.map(errorSummary) ?? ""
        errorBannerView?.isHidden = error == nil
        refreshIntervalHint.isHidden = error != nil
        if errorDetailsPopover.isShown && error == nil {
            errorDetailsPopover.performClose(nil)
        }
        errorDetailsButton.isHidden = error == nil
        refreshIntervalPopup.selectItem(withTag: Int(Preferences.shared.refreshInterval))
        refreshButton.title = isRefreshing ? "刷新…" : "刷新"
        refreshButton.isEnabled = !isRefreshing
        touchBarButton.title = "Touch Bar \(Preferences.shared.touchBarEnabled ? "开" : "关")"
        loginButton.title = "登录启动 \(SMAppService.mainApp.status == .enabled ? "开" : "关")"
    }

    private func creditText(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "积分：—" }
        if snapshot.unlimitedCredits { return "积分：不限额" }
        if let balance = snapshot.creditBalance { return "积分：\(balance)" }
        return "积分：暂无"
    }

    private func resetExpiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return "最近到期 \(formatter.string(from: date))"
    }

    private func errorSummary(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("authentication") || lower.contains("not signed in") || lower.contains("not logged") {
            return "Codex 登录状态异常"
        }
        if lower.contains("url") || lower.contains("network") || lower.contains("connection")
            || lower.contains("sending request") || lower.contains("timed out") || lower.contains("timeout") {
            return "网络请求失败"
        }
        return "额度刷新失败"
    }

    private func freshnessText(_ snapshot: UsageSnapshot?, _ freshness: SnapshotFreshness) -> String {
        guard let snapshot else { return "尚未读取额度" }
        switch freshness {
        case .live: return "在线 · \(formatUpdated(snapshot.fetchedAt))"
        case .cached: return "缓存 · \(formatUpdated(snapshot.fetchedAt))"
        case .stale: return "已过期 · \(formatUpdated(snapshot.fetchedAt))"
    }
}

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func showErrorDetails() {
        guard let currentErrorMessage else { return }
        if errorDetailsPopover.isShown {
            errorDetailsPopover.performClose(nil)
            return
        }

        let size = NSSize(width: 330, height: 190)
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active

        let title = NSTextField(labelWithString: "刷新错误详情")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: size.width - 42, height: size.height - 56)
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 11)
        textView.string = currentErrorMessage
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: size.width - 48,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineBreakMode = .byCharWrapping

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        errorCopyButton.bezelStyle = .rounded
        errorCopyButton.controlSize = .small
        errorCopyButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(scrollView)
        root.addSubview(errorCopyButton)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: size.width),
            root.heightAnchor.constraint(equalToConstant: size.height),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: errorCopyButton.topAnchor, constant: -6),
            errorCopyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            errorCopyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        let controller = NSViewController()
        controller.view = root
        controller.preferredContentSize = size
        errorDetailsPopover.contentViewController = controller
        errorDetailsPopover.contentSize = size
        errorDetailsPopover.show(relativeTo: errorDetailsButton.bounds, of: errorDetailsButton, preferredEdge: .maxY)
    }

    @objc private func copyErrorDetails() {
        guard let currentErrorMessage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentErrorMessage, forType: .string)
    }

    @objc private func refresh() { onRefresh?() }
    @objc private func changeRefreshInterval() {
        Preferences.shared.refreshInterval = TimeInterval(refreshIntervalPopup.selectedTag())
    }
    @objc private func toggleTouchBar() { onToggleTouchBar?() }
    @objc private func toggleLoginItem() { onToggleLoginItem?() }
    @objc private func quit() { onQuit?() }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        if errorDetailsPopover.isShown { errorDetailsPopover.performClose(nil) }
    }

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
