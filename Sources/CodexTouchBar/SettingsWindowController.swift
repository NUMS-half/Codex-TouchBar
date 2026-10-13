import AppKit
import ServiceManagement

/// Shared native settings grouping, with semantic colours for both appearances.
final class SettingsGroupView: NSView {
    init(title: String, subtitle: String, controls: [NSView]) {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: subtitle)
        description.font = .systemFont(ofSize: 12); description.textColor = .secondaryLabelColor
        let rows = NSStackView(views: controls)
        rows.orientation = .horizontal; rows.alignment = .centerY; rows.spacing = 28
        let stack = NSStackView(views: [heading, description, rows])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.2).setStroke(); shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
protocol LoginItemManaging: AnyObject {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}
enum LoginItemState { case enabled, disabled, requiresApproval, unavailable }

@MainActor
final class SystemLoginItemManager: LoginItemManaging {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        default: return .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

private final class SettingsBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

@MainActor
final class GeneralSettingsController: NSViewController {
    private let preferences: Preferences
    private let loginItems: any LoginItemManaging
    private let touchBarToggle = NSButton(checkboxWithTitle: "显示 Touch Bar", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let refreshInterval = NSPopUpButton(frame: .zero, pullsDown: false)
    private let backgroundInterval = NSPopUpButton(frame: .zero, pullsDown: false)
    private var refreshToggles: [QuotaRefreshTrigger: NSButton] = [:]
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettings = NSButton(title: "打开登录项设置…", target: nil, action: nil)
    private var observers: [NSObjectProtocol] = []

    init(preferences: Preferences, loginItems: any LoginItemManaging) {
        self.preferences = preferences; self.loginItems = loginItems
        super.init(nibName: nil, bundle: nil)
        _ = view
        for name in [Preferences.didChange, Preferences.refreshDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func loadView() {
        view = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        touchBarToggle.target = self; touchBarToggle.action = #selector(changeTouchBar)
        login.target = self; login.action = #selector(changeLogin)
        loginSettings.target = self; loginSettings.action = #selector(openLoginSettings)
        loginSettings.bezelStyle = .rounded; loginSettings.controlSize = .small
        for (index, popup) in [refreshInterval, backgroundInterval].enumerated() {
            popup.target = self; popup.action = #selector(changeRefreshInterval(_:)); popup.tag = index
            popup.setAccessibilityLabel(index == 0 ? "前台自动刷新间隔" : "后台自动刷新间隔")
            for interval in QuotaRefreshPolicy.intervals {
                popup.addItem(withTitle: QuotaRefreshPolicy.intervalTitle(interval))
                popup.lastItem?.tag = Int(interval)
            }
            popup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        }
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        let loginRows = NSStackView(views: [loginStatus, loginSettings])
        loginRows.orientation = .horizontal; loginRows.alignment = .centerY; loginRows.spacing = 12
        let appSwitches = NSStackView(views: [touchBarToggle, login])
        appSwitches.spacing = 28
        let appRows = NSStackView(views: [appSwitches, loginRows])
        appRows.orientation = .vertical; appRows.alignment = .leading; appRows.spacing = 8
        let appGroup = SettingsGroupView(title: "应用", subtitle: "Touch Bar仅在ChatGPT前台显示；关闭按钮会同步显示开关。", controls: [appRows])

        let events: [QuotaRefreshTrigger] = [.launch, .menuOpen, .foreground, .wake, .touchBar]
        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        rows.widthAnchor.constraint(equalToConstant: 584).isActive = true
        for trigger in events { rows.addArrangedSubview(makeRefreshToggle(trigger)) }
        let divider = NSBox(); divider.boxType = .separator
        rows.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        for (trigger, popup) in [(QuotaRefreshTrigger.foregroundTimer, refreshInterval), (.backgroundTimer, backgroundInterval)] {
            let toggle = makeRefreshToggle(trigger)
            let spacer = NSView()
            let row = NSStackView(views: [toggle, spacer, popup])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let refreshGroup = SettingsGroupView(title: "额度刷新", subtitle: "各项独立生效，睡眠时暂停。菜单栏刷新图标和右键“刷新”始终可用。", controls: [rows])
        let note = NSTextField(wrappingLabelWithString: "曲线和提醒依据成功查询更新；关闭自动刷新后，仍会记录手动查询。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [appGroup, refreshGroup, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            appGroup.widthAnchor.constraint(equalTo: stack.widthAnchor), refreshGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        refresh()
    }
    func refresh() {
        touchBarToggle.state = preferences.touchBarEnabled ? .on : .off
        let policy = preferences.refreshPolicy
        for (trigger, toggle) in refreshToggles { toggle.state = policy.allows(trigger) ? .on : .off }
        refreshInterval.selectItem(withTag: Int(policy.foregroundInterval))
        backgroundInterval.selectItem(withTag: Int(policy.backgroundInterval))
        refreshInterval.isEnabled = policy.allows(.foregroundTimer)
        backgroundInterval.isEnabled = policy.allows(.backgroundTimer)
        switch loginItems.state {
        case .enabled: login.state = .on; loginStatus.stringValue = "已开启登录启动。"
        case .disabled: login.state = .off; loginStatus.stringValue = "登录启动已关闭。"
        case .requiresApproval: login.state = .on; loginStatus.stringValue = "等待系统批准，请在登录项设置中允许。"
        case .unavailable: login.state = .off; loginStatus.stringValue = "当前系统无法定位此应用的登录项。"
        }
        loginStatus.textColor = .secondaryLabelColor
        loginSettings.isHidden = loginItems.state != .requiresApproval
    }
    @objc private func changeTouchBar() { preferences.touchBarEnabled = touchBarToggle.state == .on }
    private func makeRefreshToggle(_ trigger: QuotaRefreshTrigger) -> NSButton {
        let toggle = NSButton(checkboxWithTitle: trigger.title, target: self, action: #selector(changeRefreshToggle(_:)))
        toggle.setAccessibilityIdentifier("quotaRefresh.\(trigger.rawValue)")
        refreshToggles[trigger] = toggle
        return toggle
    }
    @objc private func changeRefreshToggle(_ sender: NSButton) {
        guard let trigger = refreshToggles.first(where: { $0.value === sender })?.key else { return }
        var policy = preferences.refreshPolicy
        policy.setEnabled(sender.state == .on, for: trigger)
        preferences.refreshPolicy = policy
        refresh()
    }
    @objc private func changeRefreshInterval(_ sender: NSPopUpButton) {
        var policy = preferences.refreshPolicy
        if sender.tag == 0 { policy.foregroundInterval = TimeInterval(sender.selectedTag()) }
        else { policy.backgroundInterval = TimeInterval(sender.selectedTag()) }
        preferences.refreshPolicy = policy
    }
    @objc private func changeLogin() {
        do { try loginItems.setEnabled(login.state == .on); refresh() }
        catch {
            refresh()
            loginStatus.stringValue = "登录启动设置失败：\(error.localizedDescription)"
            loginStatus.textColor = .systemRed
        }
    }
    @objc private func openLoginSettings() { loginItems.openSystemSettings() }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Page: String, CaseIterable {
        case general, alerts, shortcuts
        var title: String { switch self { case .general: return "通用"; case .alerts: return "额度提醒"; case .shortcuts: return "快捷操作" } }
        var symbol: String { switch self { case .general: return "slider.horizontal.3"; case .alerts: return "bell"; case .shortcuts: return "keyboard" } }
        var subtitle: String { switch self {
        case .general: return "管理应用行为和各类额度刷新触发。修改立即生效。"
        case .alerts: return "分别管理5H和周额度的低额与恢复提醒。修改自动保存。"
        case .shortcuts: return "配置四个Touch Bar按钮。预览修改后，点击保存应用。"
        } }
        var identifier: NSToolbarItem.Identifier { .init("settings.\(rawValue)") }
    }
    private let general: GeneralSettingsController
    private let alerts: UsageAlertSettingsController
    private let shortcuts: TouchBarSettingsController
    private let contentHost = NSView(frame: .zero)
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private(set) var selectedPage: Page = .general
    private var startedShortcutSession = false

    init(preferences: Preferences = .shared, service: any UsageNotificationManaging,
         desktopActions: DesktopActions? = nil, loginItems: (any LoginItemManaging)? = nil) {
        general = GeneralSettingsController(preferences: preferences, loginItems: loginItems ?? SystemLoginItemManager())
        alerts = UsageAlertSettingsController(preferences: preferences, service: service)
        shortcuts = TouchBarSettingsController(preferences: preferences, desktopActions: desktopActions ?? DesktopActions())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 672, height: 585),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "CodexTouchBar 设置"; window.isReleasedWhenClosed = false
        window.contentView = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 672, height: 585))
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "CodexTouchBar.Settings")
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .preference
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let root = window.contentView!
        for child in [heading, subtitle, contentHost] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6), subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),
            contentHost.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18), contentHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            contentHost.widthAnchor.constraint(equalToConstant: 620), contentHost.heightAnchor.constraint(equalToConstant: 480),
            contentHost.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
        select(.general)
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func show(page: Page? = nil) {
        if window?.isVisible != true && window?.isMiniaturized != true { startedShortcutSession = false }
        select(page ?? selectedPage)
        NSApp.activate(ignoringOtherApps: true); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
    }
    func select(_ page: Page, readCatalog: Bool = true) {
        window?.makeFirstResponder(nil)
        window?.defaultButtonCell = nil
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        selectedPage = page
        heading.stringValue = page.title; subtitle.stringValue = page.subtitle
        window?.toolbar?.selectedItemIdentifier = page.identifier
        let child: NSView
        switch page {
        case .general: general.refresh(); child = general.view
        case .alerts: alerts.refresh(); child = alerts.view
        case .shortcuts:
            if !startedShortcutSession { shortcuts.startSession(readCatalog: readCatalog); startedShortcutSession = true }
            child = shortcuts.view
        }
        child.frame = NSRect(x: 0, y: 0, width: 620, height: 480)
        contentHost.addSubview(child)
    }
    @objc private func selectToolbarPage(_ sender: NSToolbarItem) {
        guard let page = Page.allCases.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        select(page)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Page.allCases.map(\.identifier) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Page.allCases.map(\.identifier) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Page.allCases.map(\.identifier) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = Page.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = page.title; item.paletteLabel = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self; item.action = #selector(selectToolbarPage(_:))
        return item
    }
    func windowWillClose(_ notification: Notification) { shortcuts.endSession(); startedShortcutSession = false }
    func windowDidBecomeKey(_ notification: Notification) {
        if selectedPage == .general { general.refresh() }
        if selectedPage == .alerts { alerts.refresh() }
    }
}
