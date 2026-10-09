import AppKit
import ApplicationServices

/// Stable built-in commands. Menu actions remain independent of keybindings;
/// the unread action reads the user's current binding because it has no menu.
enum DesktopMenuAction: String, Codable, CaseIterable, Sendable {
    case newChat
    case toggleSidebar
    case settings
    case back
    case forward
    case temporaryChat
    case markUnread

    var displayName: String {
        switch self {
        case .newChat: return "新对话"
        case .toggleSidebar: return "侧边栏"
        case .settings: return "设置"
        case .back: return "后退"
        case .forward: return "前进"
        case .temporaryChat: return "临时聊天"
        case .markUnread: return "标记未读"
        }
    }

    /// Native menu titles in the current English, Simplified Chinese, and
    /// Traditional Chinese localizations. The localized title stays stable
    /// when the user changes the associated keyboard shortcut.
    private var menuTitles: [String] {
        switch self {
        case .newChat: return ["New Chat", "新聊天", "新對話"]
        case .toggleSidebar: return ["Toggle Sidebar", "显示/隐藏侧边栏", "切換側邊欄"]
        case .settings: return ["Settings…", "设置…", "設定…"]
        case .back: return ["Back", "返回"]
        case .forward: return ["Forward", "前进", "前進"]
        case .temporaryChat: return ["New Temporary Chat", "新建临时聊天", "新建臨時聊天"]
        case .markUnread: return [] // An internal app command, not a native menu item.
        }
    }

    private var topLevelTitles: [String] {
        switch self {
        case .settings: return ["ChatGPT", "Codex"]
        case .newChat, .temporaryChat: return ["File", "文件", "檔案"]
        case .toggleSidebar, .back, .forward: return ["View", "视图", "查看", "檢視"]
        case .markUnread: return []
        }
    }

    func matches(menuTitle: String) -> Bool {
        let normalized = Self.normalize(menuTitle)
        return menuTitles.contains { Self.normalize($0) == normalized }
    }

    func matches(topLevelTitle: String) -> Bool {
        let normalized = Self.normalize(topLevelTitle)
        return topLevelTitles.contains { Self.normalize($0) == normalized }
    }

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .lowercased()
    }
}

@MainActor
final class DesktopActions {
    enum ActionError: LocalizedError {
        case appNotFrontmost
        case accessibilityRequired
        case menuUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .appNotFrontmost: return "请先切回 ChatGPT"
            case .accessibilityRequired: return "请在系统设置中允许辅助功能"
            case let .menuUnavailable(name): return "\(name)暂不可用"
            }
        }
    }

    static let desktopBundleID = "com.openai.codex"

    func readCatalog() async -> DesktopMenuCatalog {
        var catalog = await Task.detached(priority: .utility) { NativeMenuAccess.readCatalog() }.value
        // Keyboard input-source APIs stay on the main actor; the menu scan
        // remains off the UI thread. Neither path adds a refresh timer.
        let shortcut = try? DesktopKeybindings().unreadShortcut()
        catalog.candidates.append(.init(command: .builtIn(.markUnread), categoryName: "应用快捷键",
            nativeTitle: "标记当前聊天未读", shortcut: shortcut?.displayName, isEnabled: shortcut != nil))
        return catalog
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func perform(_ command: DesktopCommand) throws {
        guard command.isValid else { throw ActionError.menuUnavailable(command.displayName) }
        let pid = try trustedFrontmostPID()
        if command == .builtIn(.markUnread) {
            let shortcut = try DesktopKeybindings().unreadShortcut()
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else {
                throw ActionError.menuUnavailable(command.displayName)
            }
            down.flags = shortcut.flags
            up.flags = shortcut.flags
            guard isFrontmost(pid) else { throw ActionError.appNotFrontmost }
            down.postToPid(pid)
            up.postToPid(pid)
            return
        }
        let access = NativeMenuAccess(pid: pid)
        guard let menu = access.menu(for: command) else {
            throw ActionError.menuUnavailable(command.displayName)
        }
        var item = access.find(command, under: menu)
        if item == nil {
            // Populate a lazy menu only during an explicit button press, and
            // only while that same ChatGPT process remains foreground.
            guard isFrontmost(pid) else { throw ActionError.appNotFrontmost }
            _ = AXUIElementPerformAction(menu, kAXPressAction as CFString)
            item = access.find(command, under: menu)
        }
        guard let item, access.isEnabled(item), access.canPress(item) else {
            throw ActionError.menuUnavailable(command.displayName)
        }
        guard isFrontmost(pid) else { throw ActionError.appNotFrontmost }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw ActionError.menuUnavailable(command.displayName)
        }
    }

    private func isFrontmost(_ pid: pid_t) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Self.desktopBundleID && app?.processIdentifier == pid
    }

    private func trustedFrontmostPID() throws -> pid_t {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.desktopBundleID else { throw ActionError.appNotFrontmost }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw ActionError.accessibilityRequired }
        return frontmost.processIdentifier
    }
}

/// A short-lived reader. No AX elements escape it, and catalog discovery never
/// presses menus, activates ChatGPT, or visits window/content trees.
private final class NativeMenuAccess {
    private let app: AXUIElement

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
    }

    static func readCatalog() -> DesktopMenuCatalog {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .first(where: { !$0.isTerminated }) else {
            return DesktopMenuCatalog(message: "请打开 ChatGPT 后点击“刷新 ChatGPT 功能”；常用功能仍可设置。")
        }
        guard AXIsProcessTrusted() else {
            return DesktopMenuCatalog(message: "读取 ChatGPT 专属功能需要辅助功能权限；常用功能仍可设置。", needsPermission: true)
        }
        let access = Self(pid: running.processIdentifier)
        guard let bar = access.element(access.app, kAXMenuBarAttribute as CFString) else {
            return DesktopMenuCatalog(message: "菜单尚未加载，请在 ChatGPT 打开菜单后点击“刷新 ChatGPT 功能”。")
        }
        var result = DesktopMenuCatalog()
        let deadline = Date().addingTimeInterval(2)
        var count = 0
        for menu in access.children(of: bar) {
            guard Date() < deadline, count < 200 else { break }
            let rootTitle = access.title(menu)
            let category = DesktopMenuCategory.allCases.first { $0.matches(rootTitle) }
            let settingsMenu = DesktopMenuAction.settings.matches(topLevelTitle: rootTitle)
            guard category != .edit, category != nil || settingsMenu else { continue }
            for item in access.directItems(under: menu) {
                guard Date() < deadline, count < 200 else { break }
                count += 1
                let title = access.title(item)
                guard !title.isEmpty else { continue }
                let builtIn = DesktopMenuAction.allCases.first {
                    $0.matches(topLevelTitle: rootTitle) && $0.matches(menuTitle: title)
                }
                let command: DesktopCommand
                if let builtIn {
                    command = .builtIn(builtIn)
                } else if let category {
                    command = .native(.init(category: category, title: title, identifier: access.identifier(item)))
                } else {
                    continue // Only Settings is read from the application menu.
                }
                guard command.isValid, access.children(of: item).isEmpty, access.canPress(item) else { continue }
                result.candidates.append(.init(
                    command: command, categoryName: category?.displayName ?? "应用",
                    nativeTitle: title, shortcut: access.shortcut(item), isEnabled: access.isEnabled(item)
                ))
            }
        }
        // A path/identifier must resolve uniquely. Hide ambiguous duplicates;
        // execution repeats the uniqueness check against the current menu.
        let candidates = result.candidates
        result.candidates = candidates.filter { candidate in
            candidates.filter { other in
                if case let .native(reference) = candidate.command,
                   case let .native(current) = other.command {
                    return reference.category == current.category
                        && reference.matches(title: current.title, identifier: current.identifier)
                }
                return other.command == candidate.command
            }.count == 1
        }
        if result.candidates.isEmpty {
            result.message = "未读到 ChatGPT 专属菜单功能。请打开其菜单后重试；常用功能仍可设置。"
        } else if Date() >= deadline || count >= 200 {
            result.message = "已读取部分 ChatGPT 功能，可稍后刷新。已过滤通用编辑和系统命令。"
        } else {
            result.message = "仅列出可读取的 ChatGPT 原生菜单功能，完整快捷键目录尚未接入。修改快捷键后仍可使用。"
        }
        return result
    }

    func menu(for command: DesktopCommand) -> AXUIElement? {
        guard let bar = element(app, kAXMenuBarAttribute as CFString) else { return nil }
        let matches = children(of: bar).filter { item in
            switch command {
            case let .builtIn(action): return action.matches(topLevelTitle: title(item))
            case let .native(reference): return reference.category.matches(title(item))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func find(_ command: DesktopCommand, under menu: AXUIElement) -> AXUIElement? {
        switch command {
        case let .native(reference):
            let matches = directItems(under: menu).filter {
                children(of: $0).isEmpty && reference.matches(title: title($0), identifier: identifier($0))
                    && ChatGPTMenuCommands.displayName(category: reference.category, title: title($0))
                        == ChatGPTMenuCommands.displayName(category: reference.category, title: reference.title)
            }
            return matches.count == 1 ? matches[0] : nil
        case let .builtIn(action):
            var queue: [(AXUIElement, Int)] = [(menu, 0)]
            var next = 0
            var matches: [AXUIElement] = []
            while next < queue.count && next < 160 {
                let (item, depth) = queue[next]
                next += 1
                if role(item) == kAXMenuItemRole, action.matches(menuTitle: title(item)), canPress(item) {
                    matches.append(item)
                }
                if depth < 4 { queue.append(contentsOf: children(of: item).map { ($0, depth + 1) }) }
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func directItems(under root: AXUIElement) -> [AXUIElement] {
        children(of: root).flatMap { child -> [AXUIElement] in
            if role(child) == kAXMenuRole { return children(of: child).filter { role($0) == kAXMenuItemRole } }
            return role(child) == kAXMenuItemRole ? [child] : []
        }
    }

    func isEnabled(_ item: AXUIElement) -> Bool { attribute(item, kAXEnabledAttribute as CFString) as? Bool == true }

    func canPress(_ item: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(item, &names) == .success else { return false }
        return (names as? [String])?.contains(kAXPressAction) == true
    }

    private func shortcut(_ item: AXUIElement) -> String? {
        var key = attribute(item, kAXMenuItemCmdCharAttribute as CFString) as? String ?? ""
        if key.isEmpty, let code = attribute(item, kAXMenuItemCmdVirtualKeyAttribute as CFString) as? Int {
            key = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"][code] ?? ""
        }
        guard !key.isEmpty else { return nil }
        let modifiers = attribute(item, kAXMenuItemCmdModifiersAttribute as CFString) as? Int ?? 0
        let prefix = (modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
            + (modifiers & 1 != 0 ? "⇧" : "") + (modifiers & 8 == 0 ? "⌘" : "")
        return prefix + key.uppercased()
    }

    private func title(_ item: AXUIElement) -> String { attribute(item, kAXTitleAttribute as CFString) as? String ?? "" }
    private func role(_ item: AXUIElement) -> String { attribute(item, kAXRoleAttribute as CFString) as? String ?? "" }
    private func identifier(_ item: AXUIElement) -> String? {
        let value = attribute(item, kAXIdentifierAttribute as CFString) as? String
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
    private func children(of item: AXUIElement) -> [AXUIElement] {
        (attribute(item, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
    }
    private func element(_ item: AXUIElement, _ key: CFString) -> AXUIElement? {
        guard let value = attribute(item, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func attribute(_ item: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, key, &value) == .success else { return nil }
        return value
    }
}
