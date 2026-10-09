import AppKit

private final class ButtonSettingsContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor
final class TouchBarSettingsController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let preferences: Preferences
    private let desktopActions: DesktopActions
    private var draft = TouchBarConfiguration.default.slots
    private var catalog = DesktopMenuCatalog()
    private var options: [TouchBarSlotAction] = []
    private var popups: [NSPopUpButton] = []
    private var names: [NSTextField] = []
    private var details: [NSTextField] = []
    private var previews: [TouchBarActionSlotView] = []
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "刷新 ChatGPT 功能", target: nil, action: nil)
    private let permissionButton = NSButton(title: "授权辅助功能…", target: nil, action: nil)
    private var readTask: Task<Void, Never>?
    private var readGeneration = 0

    init(preferences: Preferences, desktopActions: DesktopActions) {
        self.preferences = preferences
        self.desktopActions = desktopActions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Touch Bar 按钮设置"
        window.contentView = ButtonSettingsContentView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        renderEditor()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        let opening = !window.isVisible && !window.isMiniaturized
        if opening {
            beginEditing()
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if opening { updateCatalog() }
    }

    func beginEditing() {
        draft = preferences.touchBarConfiguration.slots
        catalog = DesktopMenuCatalog()
        statusLabel.stringValue = "仅显示可读取的 ChatGPT 原生菜单功能，保存后生效。完整快捷键目录尚未接入，刷新无需定期操作。"
        permissionButton.isHidden = true
        renderEditor()
    }

    func applyCatalog(_ result: DesktopMenuCatalog) {
        catalog = result
        catalog.candidates.removeAll { !$0.command.isValid }
        statusLabel.stringValue = result.message ?? ""
        permissionButton.isHidden = !result.needsPermission
        refreshButton.isEnabled = true
        renderEditor()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        addLabel("四个按钮区等宽，预览与 Touch Bar 使用相同样式", frame: NSRect(x: 20, y: 450, width: 580, height: 20))
        let previewBackdrop = NSView(frame: NSRect(x: 152, y: 404, width: 316, height: 42))
        previewBackdrop.wantsLayer = true
        previewBackdrop.layer?.backgroundColor = NSColor.black.cgColor
        previewBackdrop.layer?.cornerRadius = 10
        previewBackdrop.appearance = NSAppearance(named: .darkAqua)
        content.addSubview(previewBackdrop)
        for index in 0..<TouchBarConfiguration.slotCount {
            let preview = TouchBarActionSlotView(frame: NSRect(x: 10 + CGFloat(index) * 76, y: 6, width: 68, height: 30))
            preview.isPreview = true
            previewBackdrop.addSubview(preview)
            previews.append(preview)
        }
        addLabel("功能", frame: NSRect(x: 78, y: 379, width: 320, height: 18))
        addLabel("显示名称（可选）", frame: NSRect(x: 416, y: 379, width: 184, height: 18))
        for index in 0..<TouchBarConfiguration.slotCount {
            let y = CGFloat(324 - index * 60)
            addLabel("按钮 \(index + 1)", frame: NSRect(x: 20, y: y + 23, width: 56, height: 22))
            let popup = NSPopUpButton(frame: NSRect(x: 78, y: y + 20, width: 326, height: 28), pullsDown: false)
            popup.tag = index
            popup.target = self
            popup.action = #selector(selectAction(_:))
            popup.cell?.lineBreakMode = .byTruncatingTail
            popup.setAccessibilityLabel("按钮 \(index + 1) 功能")
            content.addSubview(popup)
            popups.append(popup)
            let name = NSTextField(frame: NSRect(x: 416, y: y + 23, width: 184, height: 24))
            name.tag = index
            name.delegate = self
            name.setAccessibilityLabel("按钮 \(index + 1) 显示名称")
            content.addSubview(name)
            names.append(name)
            let detail = NSTextField(labelWithString: "")
            detail.frame = NSRect(x: 78, y: y, width: 522, height: 18)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            content.addSubview(detail)
            details.append(detail)
        }
        statusLabel.frame = NSRect(x: 20, y: 91, width: 580, height: 40)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)
        refreshButton.toolTip = "重新读取 ChatGPT 菜单中的专属功能及当前快捷键；只在打开窗口或点击时读取，不执行任何功能。"
        addButton(refreshButton, frame: NSRect(x: 20, y: 58, width: 160, height: 28), action: #selector(refreshCatalog))
        addButton(permissionButton, frame: NSRect(x: 190, y: 58, width: 150, height: 28), action: #selector(requestPermission))
        let restore = NSButton(title: "恢复默认", target: nil, action: nil)
        let cancel = NSButton(title: "取消", target: nil, action: nil)
        let save = NSButton(title: "保存", target: nil, action: nil)
        addButton(restore, frame: NSRect(x: 20, y: 15, width: 110, height: 30), action: #selector(restoreDefaults))
        addButton(cancel, frame: NSRect(x: 410, y: 15, width: 90, height: 30), action: #selector(cancelEditing))
        addButton(save, frame: NSRect(x: 510, y: 15, width: 90, height: 30), action: #selector(saveConfiguration))
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
    }

    private func addLabel(_ title: String, frame: NSRect) {
        let label = NSTextField(labelWithString: title)
        label.frame = frame
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        window?.contentView?.addSubview(label)
    }

    private func addButton(_ button: NSButton, frame: NSRect, action: Selector) {
        button.frame = frame
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        window?.contentView?.addSubview(button)
    }

    private func renderEditor() {
        let common = DesktopMenuAction.allCases.map { TouchBarSlotAction.command(.builtIn($0)) } + [.navigationPair]
        let more = catalog.candidates.compactMap { candidate -> TouchBarSlotAction? in
            guard case .native = candidate.command else { return nil }
            return .command(candidate.command)
        }
        let missing = draft.map(\.action).filter { !common.contains($0) && !more.contains($0) }
        options = common
        for action in missing + more where !options.contains(action) { options.append(action) }

        for index in draft.indices {
            let popup = popups[index]
            let menu = NSMenu()
            menu.autoenablesItems = false
            addHeading("常用功能", to: menu)
            for action in common { addChoice(action, to: menu) }
            if !missing.isEmpty {
                menu.addItem(.separator())
                addHeading("已配置（当前未读取到）", to: menu)
                var added: [TouchBarSlotAction] = []
                for action in missing where !added.contains(action) {
                    addChoice(action, to: menu)
                    added.append(action)
                }
            }
            menu.addItem(.separator())
            addHeading(more.isEmpty ? "更多 ChatGPT 功能（暂未读取到）" : "更多 ChatGPT 功能", to: menu)
            for action in more { addChoice(action, to: menu) }
            popup.menu = menu
            if let selection = options.firstIndex(of: draft[index].action) { popup.selectItem(withTag: selection) }
            let navigation = draft[index].action == .navigationPair
            names[index].isEnabled = !navigation
            names[index].stringValue = draft[index].customLabel ?? ""
            names[index].placeholderString = navigation ? "固定箭头" : draft[index].buttonTitle
            updateDetail(index)
        }
        updatePreview()
    }

    private func addHeading(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if title.hasPrefix("更多 ChatGPT 功能") {
            item.toolTip = catalog.message ?? "仅读取原生菜单中的功能；ChatGPT 内部快捷键目录尚未接入。"
        }
        item.tag = -1
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addChoice(_ action: TouchBarSlotAction, to menu: NSMenu) {
        guard let tag = options.firstIndex(of: action) else { return }
        var title = action.displayName
        if case let .command(command) = action,
           let metadata = catalog.candidates.first(where: { $0.command == command }) {
            title += " · \(metadata.categoryName)"
            if let shortcut = metadata.shortcut { title += "  \(shortcut)" }
            if !metadata.isEnabled { title += "（当前不可用）" }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        item.isEnabled = true // Disabled native commands can still be configured.
        menu.addItem(item)
    }

    private func updateDetail(_ index: Int) {
        switch draft[index].action {
        case .navigationPair:
            details[index].stringValue = "左右分别执行后退、前进，共占一个按钮区"
        case let .command(command):
            if let metadata = catalog.candidates.first(where: { $0.command == command }) {
                details[index].stringValue = metadata.detail
            } else if case let .native(reference) = command {
                details[index].stringValue = "\(reference.category.displayName) · \(reference.title) · 未在当前列表中找到"
            } else if command == .builtIn(.markUnread) {
                details[index].stringValue = "应用快捷键 · 点击时读取当前绑定；清除绑定后暂不可用"
            } else {
                details[index].stringValue = "常用功能 · \(command.displayName) · 当前菜单信息未读取"
            }
        }
        details[index].toolTip = details[index].stringValue
    }

    private func updatePreview() {
        for (preview, binding) in zip(previews, draft) { preview.update(binding) }
    }

    @objc private func selectAction(_ sender: NSPopUpButton) {
        let index = sender.tag
        let option = sender.selectedTag()
        guard draft.indices.contains(index), options.indices.contains(option) else { return }
        if draft[index].action != options[option] {
            draft[index] = .init(action: options[option])
        }
        renderEditor()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, draft.indices.contains(field.tag) else { return }
        draft[field.tag].customLabel = field.stringValue
        updatePreview()
    }

    @objc private func restoreDefaults() {
        window?.makeFirstResponder(nil)
        draft = TouchBarConfiguration.default.slots
        renderEditor()
    }

    @objc private func cancelEditing() { window?.close() }

    @objc private func saveConfiguration() {
        window?.makeFirstResponder(nil)
        // Read controls once more to include the final field-editor value.
        for index in draft.indices where draft[index].action != .navigationPair {
            draft[index].customLabel = names[index].stringValue
        }
        preferences.touchBarConfiguration = TouchBarConfiguration(slots: draft)
        window?.close()
    }

    @objc private func refreshCatalog() { updateCatalog() }
    @objc private func requestPermission() { desktopActions.requestAccessibilityPermission() }

    private func updateCatalog() {
        readGeneration += 1
        let generation = readGeneration
        readTask?.cancel()
        refreshButton.isEnabled = false
        statusLabel.stringValue = "正在读取 ChatGPT 专属菜单功能…"
        readTask = Task { [weak self] in
            guard let self else { return }
            let result = await desktopActions.readCatalog()
            guard !Task.isCancelled, generation == readGeneration else { return }
            readTask = nil
            applyCatalog(result)
        }
    }

    func windowWillClose(_ notification: Notification) {
        readGeneration += 1
        readTask?.cancel()
        readTask = nil
        // Draft changes never reach Preferences unless Save was pressed.
    }
}
