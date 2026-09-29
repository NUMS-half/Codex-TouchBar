import AppKit
import ApplicationServices

/// These commands are exposed by ChatGPT's native macOS menu. Pressing a menu
/// item invokes the command itself, so a customized or cleared keybinding has
/// no effect on the Touch Bar button.
enum DesktopMenuAction {
    case newChat
    case toggleSidebar
    case settings
    case back
    case forward

    /// ChatGPT's macOS menu order: app, File, Edit, View, Window, Help.
    var topLevelIndex: Int {
        switch self {
        case .settings: return 0
        case .newChat: return 1
        case .toggleSidebar, .back, .forward: return 3
        }
    }

    var displayName: String {
        switch self {
        case .newChat: return "新对话"
        case .toggleSidebar: return "侧边栏"
        case .settings: return "设置"
        case .back: return "后退"
        case .forward: return "前进"
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
        }
    }

    private var topLevelTitles: [String] {
        switch self {
        case .settings: return ["ChatGPT", "Codex"]
        case .newChat: return ["File", "文件", "檔案"]
        case .toggleSidebar, .back, .forward: return ["View", "视图", "查看", "檢視"]
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

    private static let desktopBundleID = "com.openai.codex"

    func newChat() throws { try perform(.newChat) }
    func toggleSidebar() throws { try perform(.toggleSidebar) }
    func openSettings() throws { try perform(.settings) }
    func navigateBack() throws { try perform(.back) }
    func navigateForward() throws { try perform(.forward) }

    private func perform(_ action: DesktopMenuAction) throws {
        let pid = try trustedFrontmostPID()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let menuBar = element(app, kAXMenuBarAttribute as CFString) else {
            throw ActionError.menuUnavailable(action.displayName)
        }
        let topLevel = children(of: menuBar)
        let matchedMenu = topLevel.first {
            guard let title = attribute($0, kAXTitleAttribute as CFString) as? String else { return false }
            return action.matches(topLevelTitle: title)
        }
        let fallbackMenu = topLevel.indices.contains(action.topLevelIndex)
            ? topLevel[action.topLevelIndex] : nil
        guard let menu = matchedMenu ?? fallbackMenu else {
            throw ActionError.menuUnavailable(action.displayName)
        }
        var item = findMenuItem(action, under: menu)
        if item == nil {
            // Some macOS versions populate menu children only while the menu is open.
            _ = AXUIElementPerformAction(menu, kAXPressAction as CFString)
            item = findMenuItem(action, under: menu)
        }
        guard let item,
              (attribute(item, kAXEnabledAttribute as CFString) as? Bool) != false,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw ActionError.menuUnavailable(action.displayName)
        }
    }

    private func trustedFrontmostPID() throws -> pid_t {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.desktopBundleID else {
            throw ActionError.appNotFrontmost
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw ActionError.accessibilityRequired
        }
        return frontmost.processIdentifier
    }

    /// Search only the chosen native menu and only when a button is pressed.
    private func findMenuItem(_ action: DesktopMenuAction, under root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var next = 0
        while next < queue.count && next < 160 {
            let (item, depth) = queue[next]
            next += 1
            if let title = attribute(item, kAXTitleAttribute as CFString) as? String,
               action.matches(menuTitle: title) {
                return item
            }
            if depth < 4 {
                queue.append(contentsOf: children(of: item).map { ($0, depth + 1) })
            }
        }
        return nil
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
