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
    var onClick: (() -> Void)?

    init(kind: UsageWindowKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "点击刷新 \(kind.accessibleTitle)"
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func update(window: UsageWindow?, refreshing: Bool) {
        self.usageWindow = window
        self.refreshing = refreshing
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 3, dy: 2)
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
            drawProgress(ratio: 0, color: .tertiaryLabelColor, in: card)
            return
        }

        let remaining = usageWindow.remainingPercent
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
            .foregroundColor: statusColor(remainingPercent: remaining),
        ]
        ("\(remaining)%" as NSString).draw(at: NSPoint(x: card.minX + 31, y: card.maxY - 18), withAttributes: valueAttributes)

        let resetAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let resetText = refreshing ? "刷新中" : "重置 \(formatShortCountdown(usageWindow.resetsAt))"
        let resetSize = (resetText as NSString).size(withAttributes: resetAttributes)
        (resetText as NSString).draw(
            at: NSPoint(x: card.maxX - resetSize.width - 9, y: card.maxY - 15),
            withAttributes: resetAttributes
        )
        drawProgress(ratio: CGFloat(remaining) / 100, color: statusColor(remainingPercent: remaining), in: card)
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

/// One custom host view prevents independently-sized system items from jumping
/// as the Control Strip negotiates width.
private final class TouchBarUsageView: NSView {
    private static let cardWidth: CGFloat = 306
    private static let cardGap: CGFloat = 8
    private let fiveHour = TouchBarQuotaCard(kind: .fiveHour)
    private let weekly = TouchBarQuotaCard(kind: .weekly)

    init(onRefresh: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fiveHour.translatesAutoresizingMaskIntoConstraints = false
        weekly.translatesAutoresizingMaskIntoConstraints = false
        fiveHour.onClick = onRefresh
        weekly.onClick = onRefresh
        addSubview(fiveHour)
        addSubview(weekly)
        NSLayoutConstraint.activate([
            // Placement 0 may give the host the full app-control width. Keep
            // the actual cards compact so the Control Strip cannot cover the
            // weekly card when macOS changes its own width.
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.cardWidth * 2 + Self.cardGap),
            heightAnchor.constraint(equalToConstant: 30),
            fiveHour.leadingAnchor.constraint(equalTo: leadingAnchor),
            fiveHour.topAnchor.constraint(equalTo: topAnchor),
            fiveHour.bottomAnchor.constraint(equalTo: bottomAnchor),
            fiveHour.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            weekly.leadingAnchor.constraint(equalTo: fiveHour.trailingAnchor, constant: Self.cardGap),
            weekly.topAnchor.constraint(equalTo: topAnchor),
            weekly.bottomAnchor.constraint(equalTo: bottomAnchor),
            weekly.widthAnchor.constraint(equalToConstant: Self.cardWidth),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.cardWidth * 2 + Self.cardGap, height: 30)
    }

    func update(snapshot: UsageSnapshot?, refreshing: Bool) {
        fiveHour.update(window: snapshot?.fiveHour, refreshing: refreshing)
        weekly.update(window: snapshot?.weekly, refreshing: refreshing)
    }
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

    var onRefresh: (() -> Void)?

    override init() {
        usageView = TouchBarUsageView { }
        super.init()
        usageView.subviews.compactMap { $0 as? TouchBarQuotaCard }.forEach { [weak self] card in
            card.onClick = { self?.onRefresh?() }
        }
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.codexUsage]
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.wyx.CodexTouchBar.usage")
    }

    deinit {
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

    func update(snapshot: UsageSnapshot?, isRefreshing: Bool) {
        assert(Thread.isMainThread)
        usageView.update(snapshot: snapshot, refreshing: isRefreshing)
        fallbackView.update(snapshot)
    }

    func setVisible(_ visible: Bool) {
        shouldBeVisible = visible
        guard visible else {
            if systemModalVisible {
                SystemModalTouchBar.dismiss(touchBar)
                systemModalVisible = false
            }
            setFallbackVisible(false)
            return
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
