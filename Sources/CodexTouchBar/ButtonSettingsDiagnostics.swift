import AppKit

/// Exercises only this app's offscreen controls with an isolated preference
/// suite. It does not read ChatGPT or send any external menu action.
@MainActor
enum ButtonSettingsDiagnostics {
    private final class Notifications: @unchecked Sendable {
        var buttons = 0
        var general = 0
    }

    static func run(previewPath: String?) -> Bool {
        if let previewPath {
            do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: previewPath).deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { print("Settings preview directory failed: \(error)"); return false }
        }
        guard checkExpandedTouchBar(previewPath: previewPath),
              checkPanelAndMenuBar(previewPath: previewPath),
              UnifiedSettingsDiagnostics.run(folder: previewPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }) else { return false }
        let suite = "CodexTouchBar.ButtonsSelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let counts = Notifications()
        let center = NotificationCenter.default
        let buttonsToken = center.addObserver(forName: Preferences.buttonsDidChange, object: nil, queue: nil) { _ in counts.buttons += 1 }
        let generalToken = center.addObserver(forName: Preferences.didChange, object: nil, queue: nil) { _ in counts.general += 1 }
        defer { center.removeObserver(buttonsToken); center.removeObserver(generalToken) }
        let controller = TouchBarSettingsController(preferences: preferences, desktopActions: DesktopActions())
        controller.beginEditing()
        guard let content = Optional(controller.view) else { return false }
        let views = UIDiagnosticSupport.descendants(content)
        let popups = views.compactMap { $0 as? NSPopUpButton }.sorted { $0.tag < $1.tag }
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable).sorted { $0.tag < $1.tag }
        let previews = views.compactMap { $0 as? TouchBarActionSlotView }
        let buttons = views.compactMap { $0 as? NSButton }
        guard popups.count == 4, fields.count == 4, previews.count == 4,
              let save = buttons.first(where: { $0.title == "保存" }),
              let cancel = buttons.first(where: { $0.title == "取消" }),
              let restore = buttons.first(where: { $0.title == "恢复默认" }),
              popups[0].titleOfSelectedItem == "新对话",
              previews.allSatisfy({ $0.frame.size == NSSize(width: 68, height: 30) }) else { return false }
        for popup in popups {
            guard popup.itemArray.contains(where: { $0.title == "临时聊天" }),
                  popup.itemArray.contains(where: { $0.title == "标记未读" }) else { return false }
        }
        guard let shortcut = DesktopShortcut.parse("CmdOrCtrl+Shift+U"),
              shortcut.flags == [.maskCommand, .maskShift] else { return false }

        func rename(_ index: Int, to value: String) {
            fields[index].stringValue = value
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[index]))
        }
        rename(0, to: "取消的草稿")
        cancel.performClick(nil)
        controller.beginEditing()
        guard preferences.touchBarConfiguration == .default, fields[0].stringValue.isEmpty,
              counts.buttons == 0, counts.general == 0 else { return false }
        popups[0].selectItem(withTitle: "后退／前进")
        guard let action = popups[0].action else { return false }
        _ = NSApp.sendAction(action, to: popups[0].target, from: popups[0])
        guard !fields[0].isEnabled, previews[0].configuration.action == .navigationPair else { return false }
        popups[1].selectItem(withTitle: "新对话")
        _ = NSApp.sendAction(action, to: popups[1].target, from: popups[1])
        rename(2, to: "这是一个很长的自定义设置名称")
        let staged = TouchBarConfiguration(slots: previews.map(\.configuration))
        guard preferences.touchBarConfiguration == .default else { return false }
        save.performClick(nil)
        guard preferences.touchBarConfiguration == staged, counts.buttons == 1, counts.general == 0,
              Preferences(defaults: defaults).touchBarConfiguration == staged else { return false }
        controller.beginEditing()
        restore.performClick(nil)
        guard preferences.touchBarConfiguration == staged,
              previews.map(\.configuration) == TouchBarConfiguration.default.slots else { return false }
        cancel.performClick(nil)
        controller.beginEditing()
        guard previews.map(\.configuration) == staged.slots else { return false }
        restore.performClick(nil)
        save.performClick(nil)
        guard preferences.touchBarConfiguration == .default, counts.buttons == 2, counts.general == 0 else { return false }

        let native = DesktopCommand.native(.init(category: .view, title: "Search Chats…", identifier: "search-chats"))
        controller.beginEditing()
        controller.applyCatalog(.init(candidates: [
            .init(command: native, categoryName: "视图", nativeTitle: "Search Chats…", shortcut: "⌘K", isEnabled: false),
            .init(command: .native(.init(category: .edit, title: "Copy", identifier: "copy")), categoryName: "编辑", nativeTitle: "Copy", shortcut: "⌘C", isEnabled: true)
        ]))
        guard popups.allSatisfy({ !$0.itemArray.contains(where: { $0.title.contains("Copy") }) }) else { return false }
        guard let unavailableChoice = popups[3].itemArray.first(where: { $0.title.contains("搜索聊天") }),
              unavailableChoice.isEnabled, unavailableChoice.title.contains("当前不可用") else { return false }
        popups[3].select(unavailableChoice)
        _ = NSApp.sendAction(action, to: popups[3].target, from: popups[3])
        save.performClick(nil)
        guard preferences.touchBarConfiguration.slots[3].action == .command(native) else { return false }
        // A missing/inaccessible menu must not discard an already saved command.
        controller.beginEditing()
        controller.applyCatalog(.init(message: "测试：菜单未加载"))
        guard popups[3].titleOfSelectedItem == "搜索聊天" else { return false }
        save.performClick(nil)
        guard preferences.touchBarConfiguration.slots[3].action == .command(native),
              counts.buttons == 3, counts.general == 0 else { return false }

        let slot = TouchBarActionSlotView(frame: NSRect(x: 0, y: 0, width: 68, height: 30))
        var received: [DesktopCommand] = []
        slot.onAction = { received.append($0) }
        slot.update(.init(action: .command(native), customLabel: "只改名字"))
        slot.layout()
        guard let normal = slot.subviews.compactMap({ $0 as? NSButton }).first(where: { !$0.isHidden }),
              normal.font?.pointSize == 12, normal.cell?.lineBreakMode == .byTruncatingTail else { return false }
        normal.performClick(nil)
        slot.update(.init(action: .navigationPair))
        slot.layout()
        let arrows = slot.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        guard arrows.count == 2, arrows.allSatisfy({ $0.frame.width == 34 }) else { return false }
        arrows.forEach { $0.performClick(nil) }
        guard received == [native, .builtIn(.back), .builtIn(.forward)] else { return false }
        slot.isPreview = true
        arrows.forEach { $0.performClick(nil) }
        guard received.count == 3 else { return false }

        controller.beginEditing()
        for (index, name) in [(0, "临时聊天"), (3, "标记未读")] {
            popups[index].selectItem(withTitle: name)
            _ = NSApp.sendAction(action, to: popups[index].target, from: popups[index])
        }
        save.performClick(nil)
        guard preferences.touchBarConfiguration.slots[0].action == .command(.builtIn(.temporaryChat)),
              preferences.touchBarConfiguration.slots[3].action == .command(.builtIn(.markUnread)),
              Preferences(defaults: defaults).touchBarConfiguration == preferences.touchBarConfiguration,
              counts.buttons == 4, counts.general == 0 else { return false }

        if let previewPath {
            preferences.touchBarConfiguration = .default
            controller.beginEditing()
            do { try UIDiagnosticSupport.render(content, to: URL(fileURLWithPath: previewPath)) }
            catch { return false }
        }
        return true
    }

    private static func checkExpandedTouchBar(previewPath: String?) -> Bool {
        let controller = TouchBarController()
        let identifier = NSTouchBarItem.Identifier("com.wyx.CodexTouchBar.usage")
        guard let item = controller.touchBar(NSTouchBar(), makeItemForIdentifier: identifier) as? NSCustomTouchBarItem else { return false }
        let view = item.view
        view.frame = NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: TouchBarLayout.height)
        view.appearance = NSAppearance(named: .darkAqua)
        let now = Date()
        controller.update(snapshot: .init(
            fiveHour: .init(kind: .fiveHour, usedPercent: 43, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
            weekly: .init(kind: .weekly, usedPercent: 7, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            planType: "Plus", limitName: nil, creditBalance: nil, unlimitedCredits: false,
            availableResetCredits: 0, fetchedAt: now), freshness: .live, isRefreshing: false)
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        guard let card = buttons.first(where: { $0.title.isEmpty }),
              let back = buttons.first(where: { $0.title == "‹" }),
              let refresh = buttons.first(where: { $0.title == "↻" }) else { return false }
        view.layoutSubtreeIfNeeded()
        card.performClick(nil)
        view.layoutSubtreeIfNeeded()
        let visibleEdge = view.bounds.maxX - TouchBarLayout.navigationTrailingInset
        guard !refresh.isHidden, !back.isHidden, refresh.frame.width == 36,
              refresh.frame.maxX <= visibleEdge else {
            print("Expanded Touch Bar regression: refresh ends at \(refresh.frame.maxX), visible edge \(visibleEdge)")
            return false
        }
        let visible = view.subviews.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
        guard visible.count == 4, visible.allSatisfy({ $0.frame.minX >= 0 && $0.frame.maxX <= visibleEdge }),
              abs(visible[1].frame.width - visible[2].frame.width) < 0.001,
              zip(visible, visible.dropFirst()).allSatisfy({ abs($1.frame.minX - $0.frame.maxX - TouchBarLayout.expandedGap) < 0.001 }) else { return false }
        var refreshCalls = 0
        controller.onRefresh = { refreshCalls += 1 }
        refresh.performClick(nil)
        guard refreshCalls == 1 else { return false }
        if let previewPath {
            do {
                let folder = URL(fileURLWithPath: previewPath).deletingLastPathComponent()
                try UIDiagnosticSupport.render(view, to: folder.appendingPathComponent("touchbar-expanded.png"))
            } catch { print("Expanded Touch Bar preview failed: \(error)"); return false }
        }
        back.performClick(nil)
        view.layoutSubtreeIfNeeded()
        guard refresh.isHidden, back.isHidden,
              view.subviews.compactMap({ $0 as? TouchBarActionSlotView }).allSatisfy({ !$0.isHidden && $0.frame.width == 68 }) else { return false }
        print("Expanded Touch Bar self-test passed (visible bounds, equal cards, gaps, refresh, return)")
        return true
    }

    private static func checkPanelAndMenuBar(previewPath: String?) -> Bool {
        let fiveHour = UsageWindow(kind: .fiveHour, usedPercent: 13, durationMinutes: 300, resetsAt: Date().addingTimeInterval(3600))
        let weekly = UsageWindow(kind: .weekly, usedPercent: 36, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(86400))
        let panel = PanelController()
        panel.update(snapshot: .init(fiveHour: fiveHour, weekly: weekly, planType: "Plus", limitName: nil,
                                     creditBalance: "0", unlimitedCredits: false, availableResetCredits: 2, fetchedAt: Date()),
                     freshness: .live, error: nil, isRefreshing: false)
        let content = panel.makeContentView()
        let size = content.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        content.appearance = NSAppearance(named: .aqua)
        content.layoutSubtreeIfNeeded()
        let views = UIDiagnosticSupport.descendants(content)
        let buttons = views.compactMap { $0 as? NSButton }
        guard size.width == 340, size.height < 450,
              let settings = buttons.first(where: { $0.title == "设置…" }),
              let history = buttons.first(where: { $0.title == "额度图表…" }),
              let quit = buttons.first(where: { $0.title == "退出" }),
              let actions = settings.superview as? NSStackView,
              actions.arrangedSubviews == [history, settings, quit],
              !buttons.contains(where: { $0.title == "提醒设置…" || $0.title == "快捷操作…" || $0.title.hasPrefix("Touch Bar:") || $0.title.hasPrefix("登录启动:") }),
              buttons.contains(where: { $0.accessibilityLabel() == "刷新额度" }) else {
            print("Panel layout regression: \(size)")
            return false
        }
        var actionFrames: [NSRect] = []
        for button in [history, settings, quit] {
            let frame = content.convert(button.alignmentRect(forFrame: button.frame), from: button.superview)
            actionFrames.append(frame)
            guard content.bounds.contains(frame), frame.minX >= 15, frame.maxX <= size.width - 15 else { return false }
        }
        let gaps = zip(actionFrames, actionFrames.dropFirst()).map { $1.minX - $0.maxX }
        guard abs(actionFrames[0].minX - 16) < 0.5,
              abs(actionFrames[2].maxX - (size.width - 16)) < 0.5,
              (gaps.max() ?? 0) - (gaps.min() ?? 0) < 0.5,
              // Equal thirds can differ by one point after AppKit pixel alignment.
              actionFrames.allSatisfy({ abs($0.width - actionFrames[0].width) <= 1 }) else {
            print("Panel spacing regression: \(actionFrames), gaps \(gaps)")
            return false
        }
        var opened = 0
        panel.onShowSettings = { opened += 1 }
        settings.performClick(nil)
        guard opened == 1 else { return false }

        let readout = StatusUsageReadoutView()
        readout.update(fiveHour: fiveHour, weekly: weekly)
        let labels = readout.subviews.compactMap { $0 as? NSTextField }.filter { ["5H", "周"].contains($0.stringValue) }
        guard labels.count == 2 else { return false }
        for (appearance, minimum, maximum) in [(NSAppearance.Name.aqua, 0.0, 0.2), (.darkAqua, 0.85, 0.91)] {
            readout.appearance = NSAppearance(named: appearance)
            readout.viewDidChangeEffectiveAppearance()
            for label in labels {
                guard let color = label.textColor?.usingColorSpace(.sRGB), color.alphaComponent == 1,
                      color.redComponent >= minimum, color.redComponent <= maximum else {
                    print("Menu bar contrast regression: \(appearance), \(String(describing: label.textColor))")
                    return false
                }
            }
        }

        // Invalid legacy commands are rejected before requesting permissions
        // or inspecting/pressing any external application's menu.
        do {
            try DesktopActions().perform(.native(.init(category: .edit, title: "Copy", identifier: "copy")))
            return false
        } catch DesktopActions.ActionError.menuUnavailable { } catch { return false }

        if let previewPath {
            let folder = URL(fileURLWithPath: previewPath).deletingLastPathComponent()
            do { try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("panel-preview.png")) }
            catch { return false }
            let sampleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 90), styleMask: .borderless, backing: .buffered, defer: false)
            let sample = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 90))
            sampleWindow.contentView = sample
            for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                let background = NSView(frame: NSRect(x: 0, y: CGFloat(index) * 45, width: 210, height: 45))
                background.wantsLayer = true
                background.layer?.backgroundColor = (index == 0 ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
                    : NSColor(srgbRed: 0.32, green: 0.01, blue: 0.61, alpha: 1)).cgColor
                background.appearance = NSAppearance(named: appearance)
                sample.addSubview(background)
                let readout = StatusUsageReadoutView()
                background.addSubview(readout)
                readout.update(fiveHour: fiveHour, weekly: weekly)
                NSLayoutConstraint.activate([
                    readout.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                    readout.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                ])
            }
            sample.layoutSubtreeIfNeeded()
            do { try UIDiagnosticSupport.render(sample, to: folder.appendingPathComponent("menu-bar-appearance-preview.png")) }
            catch { return false }
        }
        return true
    }

}
