import Foundation

enum DesktopMenuCategory: String, Codable, CaseIterable, Sendable {
    case file, edit, view, help

    var displayName: String {
        switch self {
        case .file: return "文件"
        case .edit: return "编辑"
        case .view: return "视图"
        case .help: return "帮助"
        }
    }

    func matches(_ title: String) -> Bool {
        let aliases: [String]
        switch self {
        case .file: aliases = ["File", "文件", "檔案"]
        case .edit: aliases = ["Edit", "编辑", "編輯"]
        case .view: aliases = ["View", "视图", "查看", "檢視"]
        case .help: aliases = ["Help", "帮助", "輔助說明", "說明"]
        }
        return aliases.contains { $0.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }
}

/// Only a direct, static menu command is persisted, never a window/chat title
/// or an Accessibility object. Shortcuts are intentionally absent.
struct NativeMenuCommand: Codable, Equatable, Sendable {
    let category: DesktopMenuCategory
    let title: String
    let identifier: String?

    func matches(title currentTitle: String, identifier currentIdentifier: String?) -> Bool {
        if let identifier, !identifier.isEmpty { return identifier == currentIdentifier }
        return title == currentTitle
    }
}

enum DesktopCommand: Codable, Equatable, Sendable {
    case builtIn(DesktopMenuAction)
    case native(NativeMenuCommand)

    var displayName: String {
        switch self {
        case let .builtIn(action): return action.displayName
        case let .native(command): return ChatGPTMenuCommands.displayName(category: command.category, title: command.title) ?? command.title
        }
    }

    var isValid: Bool {
        switch self {
        case .builtIn: return true
        case let .native(command): return ChatGPTMenuCommands.displayName(category: command.category, title: command.title) != nil
        }
    }
}

enum TouchBarSlotAction: Codable, Equatable, Sendable {
    case command(DesktopCommand)
    case navigationPair

    var displayName: String {
        switch self {
        case let .command(command): return command.displayName
        case .navigationPair: return "后退／前进"
        }
    }
}

struct TouchBarSlotConfiguration: Codable, Equatable, Sendable {
    var action: TouchBarSlotAction
    var customLabel: String?

    var buttonTitle: String {
        if case .navigationPair = action { return "←／→" }
        if let label = cleanedLabel, !label.isEmpty { return label }
        if action == .command(.builtIn(.newChat)) { return "＋ 新对话" }
        return action.displayName.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
    }

    var cleanedLabel: String? {
        customLabel?.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalized: Self {
        var result = self
        result.customLabel = cleanedLabel.flatMap { $0.isEmpty ? nil : $0 }
        if case .navigationPair = action { result.customLabel = nil }
        return result
    }

    var isValid: Bool {
        if case let .command(command) = action { return command.isValid }
        return true
    }
}

struct TouchBarConfiguration: Equatable, Sendable {
    static let slotCount = 4
    static let defaultSlots: [TouchBarSlotConfiguration] = [
        .init(action: .command(.builtIn(.newChat))),
        .init(action: .command(.builtIn(.toggleSidebar))),
        .init(action: .command(.builtIn(.settings))),
        .init(action: .navigationPair),
    ]
    static let `default` = Self(slots: defaultSlots)
    let slots: [TouchBarSlotConfiguration]

    init(slots: [TouchBarSlotConfiguration]) {
        self.slots = (0..<Self.slotCount).map { index in
            guard slots.indices.contains(index), slots[index].isValid else { return Self.defaultSlots[index] }
            return slots[index].normalized
        }
    }

    private struct Record: Encodable {
        let version = 1
        let slots: [TouchBarSlotConfiguration]
    }

    func encoded() -> Data? { try? JSONEncoder().encode(Record(slots: slots)) }

    /// Decode slots independently so one obsolete command doesn't discard
    /// the other three user choices. Unknown record versions use defaults.
    static func decode(_ data: Data?) -> Self {
        guard let data,
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["version"] as? Int == 1,
              let values = record["slots"] as? [Any] else { return .default }
        let slots = (0..<slotCount).map { index -> TouchBarSlotConfiguration in
            guard values.indices.contains(index), JSONSerialization.isValidJSONObject(values[index]),
                  let value = try? JSONSerialization.data(withJSONObject: values[index]),
                  let slot = try? JSONDecoder().decode(TouchBarSlotConfiguration.self, from: value),
                  slot.isValid else { return defaultSlots[index] }
            return slot
        }
        return Self(slots: slots)
    }
}

struct DesktopMenuCandidate: Equatable, Sendable {
    let command: DesktopCommand
    let categoryName: String
    let nativeTitle: String
    let shortcut: String?
    let isEnabled: Bool

    var detail: String {
        [categoryName, nativeTitle, shortcut, isEnabled ? nil : "当前不可用"].compactMap { $0 }.joined(separator: " · ")
    }
}

struct DesktopMenuCatalog: Sendable {
    var candidates: [DesktopMenuCandidate] = []
    var message: String?
    var needsPermission = false
}
