import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let touchBar = TouchBarController()
    private let desktopActions = DesktopActions()
    private let panel = PanelController()
    private let usageNotifications = UsageNotificationService()
    private lazy var usageMonitoring = UsageMonitoringController(sender: usageNotifications)
    private var historyWindow: UsageHistoryWindowController?
    private lazy var settingsWindow = SettingsWindowController(service: usageNotifications, desktopActions: desktopActions)
    private var statusItem: NSStatusItem!
    private let statusReadout = StatusUsageReadoutView()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureCallbacks()
        store.onSuccessfulRefresh = { [weak self] in self?.usageMonitoring.consume($0) }
        usageMonitoring.onChange = { [weak self] in self?.historyWindow?.reload() }
        usageNotifications.onOpenHistory = { [weak self] kind in
            self?.openHistory(kind: kind)
        }
        usageMonitoring.start()
        observeWorkspace()
        configureDefaultLoginItem()
        store.onChange = { [weak self] in self?.pushState() }
        pushState()
        restartTimer()
        store.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        Task { await usageMonitoring.waitForPendingWrites(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        touchBar.setVisible(false)
    }

    private func configureCallbacks() {
        panel.onRefresh = { [weak self] in self?.store.refresh(includeResetCreditDetails: true) }
        panel.onShowHistory = { [weak self] in self?.showHistory() }
        panel.onShowSettings = { [weak self] in self?.showSettings() }
        panel.onQuit = { [weak self] in self?.quit() }
        touchBar.onRefresh = { [weak self] in self?.store.refresh() }
        touchBar.onClose = { Preferences.shared.touchBarEnabled = false }
        touchBar.onAction = { [weak self] command in
            self?.performDesktopAction { try self?.desktopActions.perform(command) }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: Preferences.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(buttonsChanged),
                                               name: Preferences.buttonsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(alertsChanged),
                                               name: Preferences.alertsDidChange, object: nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: StatusUsageReadoutView.menuItemWidth)
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.addSubview(statusReadout)
        NSLayoutConstraint.activate([
            statusReadout.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusReadout.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func configureDefaultLoginItem() {
        guard !Preferences.shared.hasAttemptedLoginSetup else { return }
        Preferences.shared.hasAttemptedLoginSetup = true
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @objc private func preferencesChanged() {
        restartTimer()
        updateTouchBarVisibility()
        pushState()
    }

    @objc private func buttonsChanged() {
        touchBar.applyConfiguration(Preferences.shared.touchBarConfiguration)
    }

    @objc private func alertsChanged() { usageMonitoring.configure() }
    @objc private func showHistory() { openHistory() }
    private func openHistory(kind: UsageWindowKind? = nil) {
        panel.close()
        if historyWindow == nil {
            historyWindow = UsageHistoryWindowController(monitor: usageMonitoring,
                snapshot: { [weak self] in self?.store.snapshot },
                isStale: { [weak self] in self?.store.freshness.isStale ?? true })
        }
        historyWindow?.show(kind: kind)
    }
    @objc private func showSettings() {
        panel.close()
        settingsWindow.show()
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        updateTouchBarVisibility()
        restartTimer()
        if isCodexFrontmost { store.refresh() }
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        timer?.invalidate()
        touchBar.setVisible(false)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        updateTouchBarVisibility()
        restartTimer()
        store.refresh()
    }

    private var isCodexFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
    }

    private func updateTouchBarVisibility() {
        let visible = Preferences.shared.touchBarEnabled
            && isCodexFrontmost
        touchBar.setVisible(visible)
    }

    private func restartTimer() {
        timer?.invalidate()
        let selectedInterval = Preferences.shared.refreshInterval
        let interval = isCodexFrontmost ? selectedInterval : 300
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick {
            contextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        store.refresh(includeResetCreditDetails: true)
        panel.show(relativeTo: button.bounds, of: button)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("刷新", #selector(refreshNow), key: "r"))
        menu.addItem(menuItem("额度曲线…", #selector(showHistory), key: ""))
        menu.addItem(menuItem("设置…", #selector(showSettings), key: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("退出", #selector(quit), key: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func quit() { NSApp.terminate(nil) }

    private func performDesktopAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            touchBar.showFeedback(error.localizedDescription)
        }
    }

    private func pushState() {
        let snapshot = store.snapshot
        panel.update(
            snapshot: snapshot,
            freshness: store.freshness,
            error: store.errorMessage,
            isRefreshing: store.isRefreshing
        )
        touchBar.update(snapshot: snapshot, freshness: store.freshness, isRefreshing: store.isRefreshing)
        updateTouchBarVisibility()

        statusReadout.update(fiveHour: snapshot?.fiveHour, weekly: snapshot?.weekly)
        guard let button = statusItem.button else { return }
        if let snapshot {
            button.toolTip = "5H \(snapshot.fiveHour.map { "\($0.remainingPercent)%" } ?? "—") · 周 \(snapshot.weekly.map { "\($0.remainingPercent)%" } ?? "—")"
        } else {
            button.toolTip = store.isRefreshing ? "正在读取 Codex 额度" : "Codex 额度不可用"
        }
    }
}
