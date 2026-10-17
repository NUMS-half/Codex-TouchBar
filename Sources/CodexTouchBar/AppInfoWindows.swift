import AppKit

private final class AppInfoContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

@MainActor
final class AppAboutWindowController: NSWindowController {
    init(info: AppBuildInfo, openURL: @escaping (URL) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 \(AppProject.name)"; window.isReleasedWhenClosed = false
        window.contentView = AppInfoContentView(frame: window.contentView!.bounds)
        super.init(window: window)
        let icon = NSImageView()
        icon.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "应用图标")
        icon.contentTintColor = icon.image?.isTemplate == true ? .controlAccentColor : nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: AppProject.name)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = NSTextField(labelWithString: info.text)
        version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
        let description = NSTextField(wrappingLabelWithString: "在菜单栏与 Touch Bar 查看 Codex 剩余额度，\n随时查看本机历史与额度提醒。")
        description.alignment = .center; description.font = .systemFont(ofSize: 12)
        let project = NSTextField(labelWithString: "NUMS-half / Codex-TouchBar")
        project.font = .systemFont(ofSize: 11); project.textColor = .secondaryLabelColor
        let homepage = LinkButton(title: "项目主页", url: AppProject.repository, openURL: openURL)
        let feedback = LinkButton(title: "反馈问题", url: AppProject.issues, openURL: openURL)
        let buttons = NSStackView(views: [homepage, feedback]); buttons.spacing = 12
        let stack = NSStackView(views: [icon, title, version, description, project, buttons])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 352), description.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func show() { showWindow(nil); window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}

@MainActor
private final class LinkButton: NSButton {
    private let url: URL
    private let openURL: (URL) -> Void
    init(title: String, url: URL, openURL: @escaping (URL) -> Void) {
        self.url = url; self.openURL = openURL
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(openLink)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func openLink() { openURL(url) }
}

@MainActor
final class AppUpdateWindowController: NSWindowController, NSWindowDelegate {
    typealias Fetch = @Sendable () async throws -> AppRelease
    enum State: Equatable { case idle, checking, available, current, ahead, unknown, failed }
    private(set) var state = State.idle
    private let info: AppBuildInfo
    private let fetch: Fetch
    private let openURL: (URL) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var release: AppRelease?
    private let heading = NSTextField(labelWithString: "检查更新")
    private let message = NSTextField(wrappingLabelWithString: "从 GitHub 获取最新正式版本。")
    private let progress = NSProgressIndicator()
    private let checkButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let releaseButton = NSButton(title: "打开发布页面", target: nil, action: nil)

    init(info: AppBuildInfo, fetch: @escaping Fetch, openURL: @escaping (URL) -> Void) {
        self.info = info; self.fetch = fetch; self.openURL = openURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "软件更新"; window.isReleasedWhenClosed = false
        window.contentView = AppInfoContentView(frame: window.contentView!.bounds)
        super.init(window: window); window.delegate = self
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let current = NSTextField(labelWithString: "当前\(info.text)")
        current.font = .systemFont(ofSize: 12); current.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12); message.maximumNumberOfLines = 3
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        checkButton.target = self; checkButton.action = #selector(check)
        releaseButton.target = self; releaseButton.action = #selector(openRelease)
        [checkButton, releaseButton].forEach { $0.bezelStyle = .rounded }
        let title = NSStackView(views: [heading, progress]); title.spacing = 10; title.alignment = .centerY
        let gap = NSView(); gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [gap, checkButton, releaseButton]); buttons.spacing = 10
        let root = window.contentView!
        for view in [title, current, message, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            current.leadingAnchor.constraint(equalTo: title.leadingAnchor), current.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor), message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            message.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        showWindow(nil); window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        check()
    }
    @objc func check() {
        guard state != .checking else { return }
        generation += 1; let ticket = generation
        state = .checking; release = nil
        heading.stringValue = "正在检查更新…"; message.stringValue = "正在获取 GitHub 上的最新正式版本。"
        progress.startAnimation(nil); checkButton.isEnabled = false; releaseButton.isEnabled = false
        task = Task { [weak self, fetch] in
            do {
                let result = try await fetch()
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.display(result)
            } catch {
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.state = .failed; self.heading.stringValue = "暂时无法检查更新"
                self.message.stringValue = (error as? AppUpdateError)?.errorDescription ?? "网络连接失败，请稍后重试，或打开发布页面查看。"
                self.finish()
            }
        }
    }
    func waitForCheck() async { await task?.value }
    private func display(_ result: AppRelease) {
        release = result
        switch result.compare(to: info.version) {
        case .newer:
            state = .available; heading.stringValue = "发现新版本 \(result.tag)"
            message.stringValue = "可前往发布页面查看更新说明并下载。"
        case .same:
            state = .current; heading.stringValue = "已是最新正式版本"
            message.stringValue = "GitHub 上的最新正式版本为 \(result.tag)。"
        case .older:
            state = .ahead; heading.stringValue = "当前版本高于最新正式版"
            message.stringValue = "GitHub 上的最新正式版本为 \(result.tag)，当前版本无需降级。"
        case .unknown:
            state = .unknown; heading.stringValue = "找到正式版本 \(result.tag)"
            message.stringValue = "当前构建未提供可比较的版本号，可在发布页面查看详情。"
        }
        finish()
    }
    private func finish() {
        progress.stopAnimation(nil); checkButton.isEnabled = true; checkButton.title = "重新检查"
        releaseButton.isEnabled = true; releaseButton.title = state == .available ? "查看更新并下载" : "打开发布页面"
    }
    @objc private func openRelease() { openURL(release?.page ?? AppProject.releases) }
    func windowWillClose(_ notification: Notification) {
        generation += 1; task?.cancel(); task = nil
        if state == .checking { state = .idle }
        progress.stopAnimation(nil)
    }
}
