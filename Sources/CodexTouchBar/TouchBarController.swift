import AppKit
import ObjectiveC

private extension NSTouchBarItem.Identifier {
    static let codexUsage = NSTouchBarItem.Identifier("com.wyx.CodexTouchBar.usage")
    static let codexFallback = NSTouchBarItem.Identifier("com.wyx.CodexTouchBar.fallback")
}

/// Isolates undocumented APIs behind runtime checks. A failure here must never
/// affect the app's menu-bar functionality.
private enum SystemModalTouchBar {
    /// `0` is the coexistence placement: the modal content uses the app-control
    /// area while macOS keeps the Control Strip (brightness, volume, Siri, …)
    /// on the right. `1` replaces the entire Touch Bar, which is appropriate
    /// for a temporary full-screen mode but not for a persistent usage readout.
    private static let coexistencePlacement = 0

    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")

    static var isAvailable: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil
            && class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    static func present(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else { return false }
        typealias PresentFunction = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: PresentFunction.self)
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            coexistencePlacement,
            "com.wyx.CodexTouchBar.system-modal" as NSString
        )
        return true
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias DismissFunction = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: DismissFunction.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
    }
}

private final class TouchBarQuotaCard: NSView {
    private let kind: UsageWindowKind
    private var usageWindow: UsageWindow?
    private var refreshing = false
    private var expanded = false
    private var isStale = false
    var onClick: (() -> Void)?

    init(kind: UsageWindowKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "点击查看 \(kind.accessibleTitle)"
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func update(window: UsageWindow?, refreshing: Bool, expanded: Bool, isStale: Bool) {
        self.usageWindow = window
        self.refreshing = refreshing
        self.expanded = expanded
        self.isStale = isStale
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0, dy: 2)
        let background = NSColor.labelColor.withAlphaComponent(0.10)
        background.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (kind.title as NSString).draw(at: NSPoint(x: card.minX + 9, y: card.maxY - 15), withAttributes: labelAttributes)

        guard let usageWindow else {
            let unavailableAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            ("N/A" as NSString).draw(at: NSPoint(x: card.minX + 31, y: card.maxY - 18), withAttributes: unavailableAttributes)
            drawSecondary("暂无额度", in: card)
            drawProgress(ratio: 0, color: .tertiaryLabelColor, in: card)
            return
        }

        let remaining = usageWindow.remainingPercent
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
            .foregroundColor: statusColor(remainingPercent: remaining),
        ]
        ("\(remaining)%" as NSString).draw(at: NSPoint(x: card.minX + 31, y: card.maxY - 18), withAttributes: valueAttributes)

        let resetTime = expanded
            ? formatResetDate(usageWindow.resetsAt)
            : formatShortCountdown(usageWindow.resetsAt)
        let resetText: String
        if refreshing {
            resetText = isStale ? "旧·刷新中" : "刷新中"
        } else if expanded {
            resetText = "\(isStale ? "旧·" : "")重置 \(resetTime)"
        } else {
            resetText = "\(isStale ? "旧·" : "")\(resetTime)"
        }
        drawSecondary(resetText, in: card)
        drawProgress(ratio: CGFloat(remaining) / 100, color: statusColor(remainingPercent: remaining), in: card)
    }

    private func drawSecondary(_ text: String, in card: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: expanded ? 10 : 9, weight: .regular),
            .foregroundColor: isStale && usageWindow != nil ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let left = card.minX + 82
        (text as NSString).draw(
            in: NSRect(x: left, y: card.maxY - 16, width: max(0, card.maxX - left - 9), height: 14),
            withAttributes: attributes
        )
    }

    private func drawProgress(ratio: CGFloat, color: NSColor, in card: NSRect) {
        let track = NSRect(x: card.minX + 9, y: card.minY + 5, width: card.width - 18, height: 4)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let width = max(0, min(track.width, track.width * ratio))
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: track.height),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }
}

/// The app-owned area remains 620 points; the right-side system Control Strip
/// is outside this view. Its normal state reserves exactly half for quota.
enum TouchBarLayout {
    static let width: CGFloat = 620
    static let height: CGFloat = 30
    static let elementGap: CGFloat = 6
    static let expandedGap: CGFloat = 8
    static let actionInset: CGFloat = 6
    static let actionCount: CGFloat = 4
    static let navigationButtonGap: CGFloat = 6

    static func compactQuotaWidth(for totalWidth: CGFloat) -> CGFloat {
        (totalWidth / 2 - elementGap) / 2
    }

    static func actionWidth(for totalWidth: CGFloat) -> CGFloat {
        (totalWidth / 2 - 2 * actionInset - (actionCount - 1) * elementGap) / actionCount
    }

    static func navigationButtonWidth(for totalWidth: CGFloat) -> CGFloat {
        (actionWidth(for: totalWidth) - navigationButtonGap) / 2
    }
}

private final class TouchBarUsageView: NSView {
    private let fiveHour = TouchBarQuotaCard(kind: .fiveHour)
    private let weekly = TouchBarQuotaCard(kind: .weekly)
    private let newChatButton = NSButton(title: "＋ 新对话", target: nil, action: nil)
    private let sidebarButton = NSButton(title: "侧边栏", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    private let navigationBackButton = NSButton(title: "←", target: nil, action: nil)
    private let navigationForwardButton = NSButton(title: "→", target: nil, action: nil)
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let refreshButton = NSButton(title: "↻", target: nil, action: nil)
    private let feedbackLabel = NSTextField(labelWithString: "")
    private var snapshot: UsageSnapshot?
    private var refreshing = false
    private var isStale = false
    private var expanded = false
    private var feedbackGeneration = 0

    var onNewChat: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onNavigateBack: (() -> Void)?
    var onNavigateForward: (() -> Void)?
    var onRefresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: TouchBarLayout.width).isActive = true
        heightAnchor.constraint(equalToConstant: TouchBarLayout.height).isActive = true

        fiveHour.onClick = { [weak self] in self?.setExpanded(true) }
        weekly.onClick = { [weak self] in self?.setExpanded(true) }
        [fiveHour, weekly].forEach(addSubview)
        configure(newChatButton, action: #selector(newChatTapped))
        configure(sidebarButton, action: #selector(sidebarTapped))
        configure(settingsButton, action: #selector(settingsTapped))
        configure(navigationBackButton, action: #selector(navigationBackTapped))
        configure(navigationForwardButton, action: #selector(navigationForwardTapped))
        configure(backButton, action: #selector(backTapped))
        configure(refreshButton, action: #selector(refreshTapped))
        backButton.font = .systemFont(ofSize: 20, weight: .medium)
        refreshButton.font = .systemFont(ofSize: 18, weight: .medium)
        navigationBackButton.font = .systemFont(ofSize: 17, weight: .medium)
        navigationForwardButton.font = .systemFont(ofSize: 17, weight: .medium)

        feedbackLabel.alignment = .center
        feedbackLabel.font = .systemFont(ofSize: 11, weight: .medium)
        feedbackLabel.textColor = .systemOrange
        feedbackLabel.isHidden = true
        addSubview(feedbackLabel)
        setExpanded(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: TouchBarLayout.width, height: TouchBarLayout.height)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let gap = TouchBarLayout.expandedGap
        if expanded {
            let edgeWidth: CGFloat = 36
            let cardWidth = (width - 2 * edgeWidth - 3 * gap) / 2
            backButton.frame = NSRect(x: 0, y: 0, width: edgeWidth, height: height)
            fiveHour.frame = NSRect(x: edgeWidth + gap, y: 0, width: cardWidth, height: height)
            weekly.frame = NSRect(x: edgeWidth + gap + cardWidth + gap, y: 0, width: cardWidth, height: height)
            refreshButton.frame = NSRect(x: width - edgeWidth, y: 0, width: edgeWidth, height: height)
        } else {
            let half = width / 2
            let cardWidth = TouchBarLayout.compactQuotaWidth(for: width)
            fiveHour.frame = NSRect(x: 0, y: 0, width: cardWidth, height: height)
            weekly.frame = NSRect(x: cardWidth + TouchBarLayout.elementGap, y: 0, width: cardWidth, height: height)
            let actionWidth = TouchBarLayout.actionWidth(for: width)
            newChatButton.frame = NSRect(x: half + TouchBarLayout.actionInset, y: 0, width: actionWidth, height: height)
            sidebarButton.frame = NSRect(x: newChatButton.frame.maxX + TouchBarLayout.elementGap, y: 0, width: actionWidth, height: height)
            settingsButton.frame = NSRect(x: sidebarButton.frame.maxX + TouchBarLayout.elementGap, y: 0, width: actionWidth, height: height)
            let navigationWidth = TouchBarLayout.navigationButtonWidth(for: width)
            navigationBackButton.frame = NSRect(x: settingsButton.frame.maxX + TouchBarLayout.elementGap, y: 0, width: navigationWidth, height: height)
            navigationForwardButton.frame = NSRect(x: navigationBackButton.frame.maxX + TouchBarLayout.navigationButtonGap, y: 0, width: navigationWidth, height: height)
            feedbackLabel.frame = NSRect(x: half, y: 0, width: half, height: height)
        }
    }

    func update(snapshot: UsageSnapshot?, refreshing: Bool, freshness: SnapshotFreshness) {
        self.snapshot = snapshot
        self.refreshing = refreshing
        isStale = freshness.isStale
        updateCards()
    }

    func refreshCountdown() {
        fiveHour.needsDisplay = true
        weekly.needsDisplay = true
    }

    func restoreDefaultLayout() {
        setExpanded(false)
        feedbackGeneration += 1
        feedbackLabel.isHidden = true
        updateActionVisibility()
    }

    func showFeedback(_ message: String) {
        guard !expanded else { return }
        feedbackGeneration += 1
        let generation = feedbackGeneration
        feedbackLabel.stringValue = message
        feedbackLabel.isHidden = false
        updateActionVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedbackGeneration == generation else { return }
            self.feedbackLabel.isHidden = true
            self.updateActionVisibility()
        }
    }

    private func setExpanded(_ value: Bool) {
        expanded = value
        backButton.isHidden = !value
        refreshButton.isHidden = !value
        updateActionVisibility()
        updateCards()
        needsLayout = true
    }

    private func updateCards() {
        fiveHour.update(window: snapshot?.fiveHour, refreshing: refreshing, expanded: expanded, isStale: isStale)
        weekly.update(window: snapshot?.weekly, refreshing: refreshing, expanded: expanded, isStale: isStale)
    }

    private func updateActionVisibility() {
        let showActions = !expanded && feedbackLabel.isHidden
        newChatButton.isHidden = !showActions
        sidebarButton.isHidden = !showActions
        settingsButton.isHidden = !showActions
        navigationBackButton.isHidden = !showActions
        navigationForwardButton.isHidden = !showActions
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        addSubview(button)
    }

    @objc private func newChatTapped() { onNewChat?() }
    @objc private func sidebarTapped() { onToggleSidebar?() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func navigationBackTapped() { onNavigateBack?() }
    @objc private func navigationForwardTapped() { onNavigateForward?() }
    @objc private func backTapped() { setExpanded(false) }
    @objc private func refreshTapped() { onRefresh?() }
}

private final class FallbackReadoutView: NSView {
    private let label = NSTextField(labelWithString: "5H — · W —")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 92),
            heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ snapshot: UsageSnapshot?) {
        let five = snapshot?.fiveHour.map { "\($0.remainingPercent)" } ?? "—"
        let week = snapshot?.weekly.map { "\($0.remainingPercent)" } ?? "—"
        label.stringValue = "5H \(five) · W \(week)"
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private let touchBar = NSTouchBar()
    private let usageView: TouchBarUsageView
    private let fallbackView = FallbackReadoutView()
    private var fallbackItem: NSCustomTouchBarItem?
    private var fallbackRegistered = false
    private var systemModalVisible = false
    private var shouldBeVisible = false
    private var countdownTimer: Timer?

    var onRefresh: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onNavigateBack: (() -> Void)?
    var onNavigateForward: (() -> Void)?

    override init() {
        usageView = TouchBarUsageView(frame: .zero)
        super.init()
        usageView.onRefresh = { [weak self] in self?.onRefresh?() }
        usageView.onNewChat = { [weak self] in self?.onNewChat?() }
        usageView.onToggleSidebar = { [weak self] in self?.onToggleSidebar?() }
        usageView.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        usageView.onNavigateBack = { [weak self] in self?.onNavigateBack?() }
        usageView.onNavigateForward = { [weak self] in self?.onNavigateForward?() }
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.codexUsage]
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.wyx.CodexTouchBar.usage")
    }

    deinit {
        countdownTimer?.invalidate()
        if systemModalVisible { SystemModalTouchBar.dismiss(touchBar) }
        unregisterFallback()
    }

    var supportsFullPresentation: Bool { SystemModalTouchBar.isAvailable }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .codexUsage else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = usageView
        item.customizationLabel = "Codex 额度"
        return item
    }

    func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, isRefreshing: Bool) {
        assert(Thread.isMainThread)
        usageView.update(snapshot: snapshot, refreshing: isRefreshing, freshness: freshness)
        fallbackView.update(snapshot)
    }

    func showFeedback(_ message: String) {
        usageView.showFeedback(message)
    }

    func setVisible(_ visible: Bool) {
        shouldBeVisible = visible
        guard visible else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            usageView.restoreDefaultLayout()
            if systemModalVisible {
                SystemModalTouchBar.dismiss(touchBar)
                systemModalVisible = false
            }
            setFallbackVisible(false)
            return
        }

        if countdownTimer == nil {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.usageView.refreshCountdown()
            }
        }

        if SystemModalTouchBar.isAvailable, !systemModalVisible, SystemModalTouchBar.present(touchBar) {
            systemModalVisible = true
            setFallbackVisible(false)
        } else if !systemModalVisible {
            setFallbackVisible(true)
        }
    }

    private func setFallbackVisible(_ visible: Bool) {
        if visible { registerFallbackIfNeeded() }
        Self.setControlStripPresence(NSTouchBarItem.Identifier.codexFallback.rawValue, visible)
    }

    private func registerFallbackIfNeeded() {
        guard !fallbackRegistered else { return }
        let item = NSCustomTouchBarItem(identifier: .codexFallback)
        item.view = fallbackView
        item.customizationLabel = "Codex 额度"
        fallbackItem = item
        fallbackRegistered = true
        Self.addSystemTrayItem(item)
    }

    private func unregisterFallback() {
        guard fallbackRegistered else { return }
        if let fallbackItem { Self.removeSystemTrayItem(fallbackItem) }
        fallbackRegistered = false
        fallbackItem = nil
    }

    private static let dfrHandle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW
    )
    private typealias DFRPresenceFunction = @convention(c) (CFString, ObjCBool) -> Void
    private static let dfrSetPresence: DFRPresenceFunction? = {
        guard let dfrHandle,
              let symbol = dlsym(dfrHandle, "DFRElementSetControlStripPresenceForIdentifier") else { return nil }
        return unsafeBitCast(symbol, to: DFRPresenceFunction.self)
    }()

    private static func setControlStripPresence(_ identifier: String, _ visible: Bool) {
        dfrSetPresence?(identifier as CFString, ObjCBool(visible))
    }

    private static func addSystemTrayItem(_ item: NSCustomTouchBarItem) {
        let selector = NSSelectorFromString("addSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: selector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
    }

    private static func removeSystemTrayItem(_ item: NSCustomTouchBarItem) {
        let selector = NSSelectorFromString("removeSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: selector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
    }
}
