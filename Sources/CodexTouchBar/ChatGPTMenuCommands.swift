import Foundation

/// An explicit allowlist of ChatGPT app commands, verified against the desktop
/// command definitions. A File/Edit/View menu alone does not imply app scope:
/// Electron also puts standard macOS editing and window commands there.
enum ChatGPTMenuCommands {
    private struct Definition {
        let category: DesktopMenuCategory
        let displayName: String
        let titles: [String]
    }

    // Only commands exposed as direct native menu items are discovered. This
    // does not make hidden command-palette actions executable through AX.
    private static let definitions: [Definition] = [
        .init(category: .file, displayName: "新窗口", titles: ["New Window", "新窗口", "新視窗"]),
        .init(category: .file, displayName: "临时聊天", titles: ["New Temporary Chat", "新建临时聊天", "新建臨時聊天"]),
        .init(category: .file, displayName: "独立聊天", titles: ["New standalone chat", "新建独立聊天", "新建獨立聊天"]),
        .init(category: .file, displayName: "打开文件夹", titles: ["Open Folder…", "打开文件夹…", "開啟資料夾…"]),
        .init(category: .view, displayName: "命令菜单", titles: ["Open command menu", "打开命令菜单", "開啟命令選單"]),
        .init(category: .view, displayName: "搜索聊天", titles: ["Search Chats…", "搜索聊天…", "搜尋聊天…"]),
        .init(category: .view, displayName: "搜索文件", titles: ["Search Files…", "搜索文件…", "搜尋檔案…"]),
        .init(category: .view, displayName: "聊天内查找", titles: ["Find", "查找", "尋找"]),
        .init(category: .view, displayName: "上个聊天", titles: ["Previous Chat", "上一个聊天", "上一個聊天"]),
        .init(category: .view, displayName: "下个聊天", titles: ["Next Chat", "下一个聊天", "下一個聊天"]),
        .init(category: .view, displayName: "底部面板", titles: ["Toggle Bottom Panel", "显示/隐藏底部面板", "顯示/隱藏底部面板"]),
        .init(category: .view, displayName: "固定摘要", titles: ["Toggle Pinned Summary", "显示/隐藏固定摘要", "顯示/隱藏固定摘要"]),
        .init(category: .view, displayName: "终端", titles: ["Open Terminal", "打开终端", "開啟終端機"]),
        .init(category: .view, displayName: "导航面板", titles: ["Toggle navigation panel", "显示/隐藏导航面板", "顯示/隱藏導覽面板"]),
        .init(category: .view, displayName: "变更面板", titles: ["Toggle Changes Panel", "显示/隐藏“变更”面板", "顯示/隱藏「變更」面板"]),
        .init(category: .view, displayName: "归档聊天", titles: ["Archive chat", "归档聊天", "封存聊天"]),
        .init(category: .view, displayName: "重命名聊天", titles: ["Rename chat", "重命名聊天", "重新命名聊天"]),
        .init(category: .view, displayName: "置顶聊天", titles: ["Pin/unpin chat", "置顶/取消置顶聊天", "釘選/取消釘選聊天"]),
        .init(category: .help, displayName: "快捷键设置", titles: ["Keyboard Shortcuts", "键盘快捷键", "鍵盤快捷鍵"]),
    ]

    static func displayName(category: DesktopMenuCategory, title: String) -> String? {
        let title = normalized(title)
        return definitions.first {
            $0.category == category && $0.titles.contains { normalized($0) == title }
        }?.displayName
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .lowercased()
    }
}
