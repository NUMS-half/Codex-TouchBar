import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let touchBar = TouchBarSession()
    private var touchBarSupport = TouchBarSupport(hardware: .unknown)
    private let desktopActions = DesktopActions()
    private let panel = PanelController()
    private let appMenu = AppMenuController()
    private let usageNotifications = UsageNotificationService()
    private lazy var usageMonitoring = UsageMonitoringController(sender: usageNotifications)
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private let statusReadout = StatusUsageReadoutView()
    private let refreshTimer = QuotaRefreshTimer()
    private var isSleeping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureCallbacks()
        refreshTouchBarSupport()
        store.onSuccessfulRefresh = { [weak self] in self?.usageMonitoring.consume($0) }
        usageMonitoring.onChange = { [weak self] in self?.panel.reloadHistory(); self?.pushState() }
        usageNotifications.onOpenHistory = { [weak self] kind in
            self?.openHistory(kind: kind)
        }
        usageNotifications.onOpenQuota = { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.requestRefresh(.menuOpen, includeResetCreditDetails: true)
            if !self.panel.isShown { self.panel.show(relativeTo: button.bounds, of: button) }
            self.panel.showOverview()
        }
        usageMonitoring.start()
        observeWorkspace()
        configureDefaultLoginItem()
        store.onChange = { [weak self] in self?.pushState() }
        pushState()
        restartTimer()
        requestRefresh(.launch)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        refreshTimer.stop()
        Task { await usageMonitoring.waitForPendingWrites(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer.stop()
        touchBar.stop()
    }

    private func configureCallbacks() {
        panel.configureHistory(monitor: usageMonitoring, snapshot: { [weak self] in self?.store.snapshot },
                               isStale: { [weak self] in self?.store.freshness.isStale ?? true })
        panel.onRefresh = { [weak self] in self?.requestRefresh(.manual, includeResetCreditDetails: true) }
        panel.onShowHistory = { [weak self] in self?.showHistory() }
        panel.onShowSettings = { [weak self] in self?.showSettings() }
        panel.onQuit = { [weak self] in self?.quit() }
        appMenu.onRefresh = { [weak self] in self?.requestRefresh(.manual, includeResetCreditDetails: true) }
        appMenu.onHistory = { [weak self] in self?.showHistory() }
        appMenu.onSettings = { [weak self] in self?.showSettings() }
        appMenu.onQuit = { [weak self] in self?.quit() }
        panel.onDisplayTick = { [weak self] in self?.pushState() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: Preferences.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPreferencesChanged),
                                               name: Preferences.refreshDidChange, object: nil)
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

    @objc private func refreshPreferencesChanged() { restartTimer() }

    @objc private func preferencesChanged() {
        pushState()
    }

    @objc private func buttonsChanged() {
        touchBar.controller?.applyConfiguration(Preferences.shared.touchBarConfiguration)
    }

    @objc private func alertsChanged() { usageMonitoring.configure() }
    @objc private func showHistory() { openHistory() }
    private func openHistory(kind: UsageWindowKind? = nil) {
        guard let button = statusItem.button else { return }
        if !panel.isShown { panel.show(relativeTo: button.bounds, of: button) }
        panel.showHistory(kind: kind)
    }
    @objc private func showSettings() {
        panel.close()
        refreshTouchBarSupport()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(service: usageNotifications, desktopActions: desktopActions,
                                                      touchBarSupport: touchBarSupport)
        }
        settingsWindow?.show()
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        updateTouchBarVisibility()
        restartTimer(forceRestart: false)
        if isCodexFrontmost { requestRefresh(.foreground) }
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        isSleeping = true
        refreshTimer.stop()
        touchBar.controller?.setVisible(false)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        isSleeping = false
        refreshTouchBarSupport()
        restartTimer()
        requestRefresh(.wake)
    }

    private var isCodexFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ApplicationIdentity.chatGPTBundleIdentifier
    }

    private func refreshTouchBarSupport() {
        touchBarSupport = TouchBarSystem.detect()
        settingsWindow?.updateTouchBarSupport(touchBarSupport)
        updateTouchBarVisibility()
    }

    private func updateTouchBarVisibility() {
        touchBar.synchronize(support: touchBarSupport, enabled: Preferences.shared.touchBarEnabled,
                             visible: !isSleeping && isCodexFrontmost) { [self] in
            let controller = TouchBarController()
            controller.onRefresh = { [weak self] in
                guard let self else { return }
                if !self.requestRefresh(.touchBar) {
                    self.touchBar.controller?.showFeedback("Touch Bar刷新已关闭，可在通用设置中开启")
                }
            }
            controller.onClose = { Preferences.shared.touchBarEnabled = false }
            controller.onAction = { [weak self] command in
                self?.performDesktopAction { try self?.desktopActions.perform(command) }
            }
            controller.applyConfiguration(Preferences.shared.touchBarConfiguration)
            controller.update(snapshot: store.snapshot, freshness: store.freshness, isRefreshing: store.isRefreshing)
            return controller
        }
    }

    @discardableResult
    private func requestRefresh(_ trigger: QuotaRefreshTrigger, includeResetCreditDetails: Bool = false) -> Bool {
        guard !isSleeping else { return false }
        return Preferences.shared.refreshPolicy.perform(trigger) {
            store.refresh(includeResetCreditDetails: QuotaRefreshPolicy.includesResetCreditDetails(
                explicit: includeResetCreditDetails,
                panelVisible: panel.isShown,
                expiryReminderEnabled: Preferences.shared.usageAlertOptions.resetExpiry
            ))
        }
    }

    private func restartTimer(forceRestart: Bool = true) {
        guard !isSleeping else { refreshTimer.stop(); return }
        let foreground = isCodexFrontmost
        refreshTimer.update(isForeground: foreground,
                            interval: Preferences.shared.refreshPolicy.timerInterval(isForeground: foreground),
                            forceRestart: forceRestart) { [weak self] in
            guard let self else { return }
            self.requestRefresh(self.isCodexFrontmost ? .foregroundTimer : .backgroundTimer)
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick {
            panel.close()
            appMenu.makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        if !panel.isShown { requestRefresh(.menuOpen, includeResetCreditDetails: true) }
        panel.show(relativeTo: button.bounds, of: button)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func performDesktopAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            touchBar.controller?.showFeedback(error.localizedDescription)
        }
    }

    private func pushState() {
        let snapshot = store.snapshot
        panel.update(
            snapshot: snapshot,
            freshness: store.freshness,
            error: store.errorMessage,
            isRefreshing: store.isRefreshing,
            recentChanges: usageMonitoring.recentChangesAt == snapshot?.fetchedAt ? usageMonitoring.recentChanges : [:]
        )
        touchBar.controller?.update(snapshot: snapshot, freshness: store.freshness, isRefreshing: store.isRefreshing)
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
