import AppKit

@MainActor
enum UnifiedSettingsDiagnostics {
    final class LoginItems: LoginItemManaging {
        var state = LoginItemState.disabled
        var fail = false
        var calls = 0
        func setEnabled(_ enabled: Bool) throws {
            calls += 1
            if fail { throw UsageMonitoringDiagnostics.CheckFailure(message: "simulated login failure") }
            state = enabled ? .enabled : .disabled
        }
        func openSystemSettings() {}
    }
    static func run(folder: URL?) -> Bool {
        let suite = "CodexTouchBar.UnifiedSettings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let service = UsageMonitoringUIDiagnostics.FakeNotifications()
        service.status = .allowed
        let loginItems = LoginItems()
        let controller = SettingsWindowController(preferences: preferences, service: service, loginItems: loginItems,
                                                  touchBarSupport: .init(hardware: .present, fullPresentation: true))
        let check = UsageMonitoringDiagnostics.check
        do {
            let window = controller.window!
            let content = window.contentView!
            try check(window.toolbar?.items.map(\.label) == ["通用", "额度提醒", "快捷操作"], "three unified settings pages")
            func buttons() -> [NSButton] { UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSButton } }
            let touch = buttons().first { $0.title == "显示 Touch Bar" }!
            let login = buttons().first { $0.title == "登录时启动" }!
            touch.performClick(nil)
            try check(!preferences.touchBarEnabled, "general Touch Bar switch applies")
            preferences.touchBarEnabled = true
            controller.select(.general)
            try check(touch.state == .on, "external Touch Bar changes reflected")
            login.performClick(nil)
            try check(loginItems.state == .enabled && login.state == .on, "login switch applies")
            loginItems.fail = true
            login.performClick(nil)
            try check(login.state == .on && loginItems.state == .enabled, "login error rolls switch back")
            loginItems.fail = false
            let interval = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "前台自动刷新间隔" }!
            interval.selectItem(withTag: 120)
            NSApp.sendAction(interval.action!, to: interval.target, from: interval)
            try check(preferences.refreshPolicy.foregroundInterval == 120, "refresh interval moved to general settings")

            let background = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "后台自动刷新间隔" }!
            background.selectItem(withTag: 600)
            NSApp.sendAction(background.action!, to: background.target, from: background)
            try check(preferences.refreshPolicy.backgroundInterval == 600, "background interval persists")
            for trigger in QuotaRefreshTrigger.allCases where trigger != .manual {
                let toggle = buttons().first { $0.title == trigger.title }!
                try check(toggle.state == .on, "passive refresh defaults enabled")
                toggle.performClick(nil)
                try check(!preferences.refreshPolicy.allows(trigger), "each refresh switch applies independently")
            }
            try check(!interval.isEnabled && !background.isEnabled, "disabled timers disable their interval selectors")
            try check(preferences.refreshPolicy.allows(.manual), "manual refresh remains available")
            let restored = Preferences(defaults: defaults).refreshPolicy
            try check(QuotaRefreshTrigger.allCases.filter { $0 != .manual }.allSatisfy { !restored.allows($0) }, "all disabled triggers survive restart")
            buttons().first { $0.title == QuotaRefreshTrigger.foregroundTimer.title }!.performClick(nil)
            try check(interval.isEnabled && !background.isEnabled && interval.selectedTag() == 120, "re-enabling one timer preserves interval and other timer state")

            controller.select(.shortcuts, readCatalog: false)
            func fields() -> [NSTextField] { UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable).sorted { $0.tag < $1.tag } }
            func rename(_ value: String) {
                let field = fields()[0]; field.stringValue = value
                (field.delegate as? TouchBarSettingsController)?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            rename("草稿保留")
            controller.select(.general); controller.select(.shortcuts, readCatalog: false)
            try check(fields()[0].stringValue == "草稿保留" && preferences.touchBarConfiguration == .default, "page switch preserves unsaved draft")
            buttons().first { $0.title == "取消" }!.performClick(nil)
            try check(fields()[0].stringValue.isEmpty && preferences.touchBarConfiguration == .default, "cancel restores persisted settings")
            rename("已保存")
            buttons().first { $0.title == "保存" }!.performClick(nil)
            try check(preferences.touchBarConfiguration.slots[0].customLabel == "已保存", "save applies shortcuts")
            rename("关闭丢弃")
            window.close()
            controller.select(.shortcuts, readCatalog: false)
            try check(fields()[0].stringValue == "已保存", "close discards draft")

            controller.select(.alerts)
            buttons().first { $0.title == "5H低额提醒" }!.performClick(nil)
            try check(preferences.usageAlertOptions.fiveHourLow, "alert switch saves in unified window")
            let inputs = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable).sorted { $0.tag < $1.tag }
            try check(inputs.count == 4 && inputs.map(\.integerValue) == [20, 20, 100, 100], "four configurable default thresholds")
            inputs[0].stringValue = "35"
            inputs[0].delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: inputs[0]))
            try check(preferences.usageAlertOptions.fiveHourLowThreshold == 35 && Preferences(defaults: defaults).usageAlertOptions.fiveHourLowThreshold == 35, "typed threshold saved and persists")
            inputs[0].stringValue = "101"
            inputs[0].delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: inputs[0]))
            inputs[0].delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: inputs[0]))
            try check(preferences.usageAlertOptions.fiveHourLowThreshold == 35 && inputs[0].integerValue == 35, "invalid input preserves previous threshold")
            let stepper = UIDiagnosticSupport.descendants(content).compactMap { $0 as? NSStepper }.first { $0.tag == 0 }!
            stepper.integerValue = 36
            NSApp.sendAction(stepper.action!, to: stepper.target, from: stepper)
            try check(preferences.usageAlertOptions.fiveHourLowThreshold == 36, "threshold stepper saves")

            try check(loginItems.calls == 2, "other pages do not modify login item")
            if let folder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for page in SettingsWindowController.Page.allCases {
                    controller.select(page, readCatalog: false)
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        window.appearance = NSAppearance(named: appearance)
                        content.layoutSubtreeIfNeeded()
                        for control in UIDiagnosticSupport.descendants(content).filter({ $0 is NSControl && !$0.isHidden }) {
                            let rect = content.convert(control.bounds, from: control)
                            try check(content.bounds.insetBy(dx: -6, dy: -6).contains(rect), "unified settings controls fit")
                        }
                        try UIDiagnosticSupport.render(content.superview ?? content, to: folder.appendingPathComponent("settings-\(page.rawValue)-\(appearance.rawValue).png"))
                    }
                }
            }
            print("Unified settings self-test passed (navigation, draft lifecycle, general switches, login failure, alerts, appearances)")
            return true
        } catch { print("Unified settings self-test failed: \(error)"); return false }
    }
}
