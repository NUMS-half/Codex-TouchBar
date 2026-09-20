import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let touchBar = TouchBarController()
    private let panel = PanelController()
    private var statusItem: NSStatusItem!
    private let statusReadout = StatusUsageReadoutView()
    private var timer: Timer?
    private var configurationError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureCallbacks()
        observeWorkspace()
        configureDefaultLoginItem()
        store.onChange = { [weak self] in self?.pushState() }
        pushState()
        restartTimer()
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        touchBar.setVisible(false)
    }

    private func configureCallbacks() {
        panel.onRefresh = { [weak self] in self?.store.refresh() }
        panel.onToggleTouchBar = { [weak self] in self?.toggleTouchBar() }
        panel.onToggleLoginItem = { [weak self] in self?.toggleLoginItem() }
        panel.onQuit = { NSApp.terminate(nil) }
        touchBar.onRefresh = { [weak self] in self?.store.refresh() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: Preferences.didChange,
            object: nil
        )
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
        store.refresh()
        panel.show(relativeTo: button.bounds, of: button)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("刷新", #selector(refreshNow), key: "r"))
        menu.addItem(menuItem(
            "Touch Bar：\(Preferences.shared.touchBarEnabled ? "关闭" : "开启")",
            #selector(toggleTouchBar),
            key: ""
        ))
        menu.addItem(menuItem(
            "登录启动：\(SMAppService.mainApp.status == .enabled ? "关闭" : "开启")",
            #selector(toggleLoginItem),
            key: ""
        ))
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

    @objc private func toggleTouchBar() {
        Preferences.shared.touchBarEnabled.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            configurationError = nil
        } catch {
            configurationError = "登录启动设置失败：\(error.localizedDescription)"
        }
        pushState()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func pushState() {
        let snapshot = store.snapshot
        panel.update(
            snapshot: snapshot,
            freshness: store.freshness,
            error: store.errorMessage ?? configurationError,
            isRefreshing: store.isRefreshing
        )
        touchBar.update(snapshot: snapshot, isRefreshing: store.isRefreshing)
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
