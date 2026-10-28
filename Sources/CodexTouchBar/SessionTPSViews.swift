import AppKit
import ApplicationServices

@MainActor
final class SessionTPSSettingsView: NSView {
    private let preferences: Preferences
    private var touchBarSupport: TouchBarSupport
    private let menuBarToggle = NSButton(checkboxWithTitle: "在菜单栏显示 TPS", target: nil, action: nil)
    private let permissionButton = NSButton(title: "授权识别当前对话…", target: nil, action: nil)
    private let accessibilityTrusted: () -> Bool
    private let requestAccessibility: () -> Void
    private let note = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?

    init(preferences: Preferences, touchBarSupport: TouchBarSupport,
         accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestAccessibility: @escaping () -> Void = { SessionVisibleConversation.requestAccessibilityAccess() }) {
        self.preferences = preferences; self.touchBarSupport = touchBarSupport
        self.accessibilityTrusted = accessibilityTrusted; self.requestAccessibility = requestAccessibility
        super.init(frame: .zero)
        menuBarToggle.setAccessibilityIdentifier("sessionTPS.menuBar")
        for toggle in [menuBarToggle] { toggle.target = self; toggle.action = #selector(changed) }
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        permissionButton.bezelStyle = .rounded; permissionButton.font = .systemFont(ofSize: 11)
        permissionButton.target = self; permissionButton.action = #selector(requestAccess)
        permissionButton.setAccessibilityIdentifier("sessionTPS.accessibility")
        let controls = NSStackView(views: [menuBarToggle, note, permissionButton])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 8
        let group = SettingsGroupView(title: "会话速度", subtitle: "显示当前对话的模型输出速度，例如 ⚡ 243 tok/s；在模型响应完成后更新。", controls: [controls])
        group.translatesAutoresizingMaskIntoConstraints = false; addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: leadingAnchor), group.trailingAnchor.constraint(equalTo: trailingAnchor),
            group.topAnchor.constraint(equalTo: topAnchor), group.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -36),
        ])
        observer = NotificationCenter.default.addObserver(forName: Preferences.sessionTPSDidChange, object: preferences, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func updateTouchBarSupport(_ support: TouchBarSupport) { touchBarSupport = support; refresh() }
    func refresh() {
        menuBarToggle.state = preferences.sessionTPSOptions.menuBar ? .on : .off
        permissionButton.isHidden = accessibilityTrusted()
        note.stringValue = touchBarSupport.isUsable
            ? "菜单栏左侧显示速度和 tok/s，右侧显示 H／W 额度。Touch Bar 请在「快捷操作」中将任意一个位置设为「当前对话 TPS」；仅显示，点击无操作。仅用窗口标题识别对话；若无法读取，可授权辅助功能。"
            : "显示在菜单栏两行读数中，左侧为速度和 tok/s，右侧为 H／W 额度；仅用窗口标题识别对话；若无法读取，可授权辅助功能。"
    }
    @objc private func requestAccess() { requestAccessibility(); refresh() }
    @objc private func changed() {
        var options = preferences.sessionTPSOptions
        options.menuBar = menuBarToggle.state == .on
        preferences.sessionTPSOptions = options
        refresh()
    }
}
