import Carbon
import CoreGraphics
import Foundation

/// Reads only ChatGPT's standalone shortcut settings. No credentials, chat
/// state, or Accessibility objects are read or retained here.
struct DesktopKeybindings {
    enum BindingError: LocalizedError {
        case unreadable, unassigned, unsupported, conflict

        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取快捷键"
            case .unassigned: return "未设置快捷键"
            case .unsupported: return "组合键暂不支持"
            case .conflict: return "快捷键存在冲突"
            }
        }
    }

    struct Entry: Decodable {
        let command: String
        let key: String?

        private enum CodingKeys: String, CodingKey { case command, key }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            // Missing keys are not the same as an explicit cleared binding.
            guard container.contains(.key) else { throw BindingError.unreadable }
            key = try container.decodeIfPresent(String.self, forKey: .key)
        }
    }

    let url: URL

    init(url: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.url = url ?? home.appendingPathComponent("keybindings.json")
    }

    func unreadShortcut(lookup: DesktopShortcut.KeyLookup = DesktopShortcut.layoutKey) throws -> DesktopShortcut {
        let data: Data?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else {
                throw BindingError.unreadable
            }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            data = nil
        } catch { throw BindingError.unreadable }
        return try Self.resolveUnread(data: data, lookup: lookup)
    }

    static func resolveUnread(data: Data?, lookup: DesktopShortcut.KeyLookup = DesktopShortcut.layoutKey) throws -> DesktopShortcut {
        let entries: [Entry]
        if let data {
            guard let values = try? JSONDecoder().decode([Entry].self, from: data) else { throw BindingError.unreadable }
            entries = values
        } else {
            entries = [] // No overrides: use the verified ChatGPT default.
        }
        let overrides = entries.filter { $0.command == "markThreadUnread" }
        if overrides.contains(where: { $0.key == nil }) { throw BindingError.unassigned }
        let choices = overrides.isEmpty ? ["CmdOrCtrl+Shift+U"] : overrides.compactMap(\.key)
        for raw in choices {
            guard let shortcut = DesktopShortcut.parse(raw, lookup: lookup) else { continue }
            // A conflicting manually edited keymap must not trigger a
            // different command. Also reject another command's chord prefix.
            let conflict = entries.contains { entry in
                guard entry.command != "markThreadUnread", let raw = entry.key,
                      let first = raw.split(whereSeparator: \.isWhitespace).first,
                      let other = DesktopShortcut.parse(String(first), lookup: lookup) else { return false }
                return other.keyCode == shortcut.keyCode && other.flags == shortcut.flags
            }
            guard !conflict else { throw BindingError.conflict }
            return shortcut
        }
        throw BindingError.unsupported
    }
}

struct DesktopShortcut {
    typealias KeyLookup = (String) -> (CGKeyCode, CGEventFlags)?
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let displayName: String

    /// Accept a single app shortcut, never plain text or a partial chord.
    /// Missing/unsupported bindings fail rather than reverting to old keys.
    static func parse(_ raw: String, lookup: KeyLookup = layoutKey) -> Self? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isWhitespace) else { return nil }
        let tokens = raw.components(separatedBy: "+")
        guard let key = tokens.last, !key.isEmpty else { return nil }
        var flags = CGEventFlags()
        for modifier in tokens.dropLast() {
            switch modifier.lowercased() {
            case "cmdorctrl", "commandorcontrol", "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        guard !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              let (code, implicitFlags) = namedKey(key) ?? lookup(key.lowercased()) else { return nil }
        flags.formUnion(implicitFlags)
        let prefix = (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "")
            + (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "")
        return Self(keyCode: code, flags: flags, displayName: prefix + key.uppercased())
    }

    private static func namedKey(_ key: String) -> (CGKeyCode, CGEventFlags)? {
        let codes: [String: CGKeyCode] = ["enter": 36, "return": 36, "tab": 48, "space": 49,
            "backspace": 51, "escape": 53, "esc": 53, "delete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
            "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]
        return codes[key.lowercased()].map { ($0, []) }
    }

    /// Use the active ASCII-capable layout (also works with Chinese IMEs),
    /// rather than guessing US physical key positions for custom bindings.
    static func layoutKey(_ key: String) -> (CGKeyCode, CGEventFlags)? {
        let key = ["plus": "+", "minus": "-" ][key] ?? key
        guard key.utf16.count == 1,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for (modifiers, flags) in [(UInt32(0), CGEventFlags()), (UInt32(2), CGEventFlags.maskShift)] {
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                    characters.count, &length, &characters)
                if result == noErr, length > 0,
                   String(utf16CodeUnits: characters, count: length).lowercased() == key {
                    return (code, flags)
                }
            }
        }
        return nil
    }
}
