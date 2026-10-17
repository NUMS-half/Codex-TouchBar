import AppKit

@MainActor
final class AppMenuController: NSObject {
    var onRefresh: () -> Void = {}
    var onHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    private let info: AppBuildInfo
    private let fetch: AppUpdateWindowController.Fetch
    private let openURL: (URL) -> Void
    private var aboutWindow: AppAboutWindowController?
    private var updateWindow: AppUpdateWindowController?

    init(info: AppBuildInfo = .current,
         fetch: @escaping AppUpdateWindowController.Fetch = { try await AppReleaseClient().latest() },
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.info = info; self.fetch = fetch; self.openURL = openURL
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(item("刷新额度", #selector(refresh), key: "r", symbol: "arrow.clockwise"))
        menu.addItem(item("额度图表…", #selector(history), symbol: "chart.bar"))
        menu.addItem(item("设置…", #selector(settings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())
        let checking = updateWindow?.state == .checking
        let update = item(checking ? "正在检查更新…" : "检查更新…", #selector(checkUpdates), symbol: "arrow.down.circle")
        update.isEnabled = !checking; menu.addItem(update)
        menu.addItem(item("关于 \(AppProject.name)…", #selector(about), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(item("使用说明", #selector(help), symbol: "questionmark.circle"))
        menu.addItem(item("反馈问题…", #selector(feedback), symbol: "bubble.left"))
        menu.addItem(.separator())
        menu.addItem(item("退出 \(AppProject.name)", #selector(quit), key: "q", symbol: "power"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        return item
    }
    @objc private func refresh() { onRefresh() }
    @objc private func history() { onHistory() }
    @objc private func settings() { onSettings() }
    @objc private func quit() { onQuit() }
    @objc private func help() { openURL(AppProject.help) }
    @objc private func feedback() { openURL(AppProject.issues) }
    @objc private func about() {
        if aboutWindow == nil { aboutWindow = AppAboutWindowController(info: info, openURL: openURL) }
        aboutWindow?.show()
    }
    @objc private func checkUpdates() {
        if updateWindow == nil { updateWindow = AppUpdateWindowController(info: info, fetch: fetch, openURL: openURL) }
        updateWindow?.show()
    }
}
