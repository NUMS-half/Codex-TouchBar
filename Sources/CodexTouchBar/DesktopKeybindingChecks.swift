import Foundation
import CoreGraphics

enum DesktopKeybindingChecks {
    static func run() -> Bool {
        let lookup: DesktopShortcut.KeyLookup = { key in
            ["u": CGKeyCode(32), "k": 40][key].map { ($0, []) }
        }
        func resolve(_ json: String?) throws -> DesktopShortcut {
            try DesktopKeybindings.resolveUnread(data: json.map { Data($0.utf8) }, lookup: lookup)
        }
        func rejects(_ json: String) -> Bool {
            do { _ = try resolve(json); return false } catch { return true }
        }
        do {
            let initial = try resolve(nil)
            guard initial.keyCode == 32, initial.flags == [.maskCommand, .maskShift],
                  try resolve("[]").flags == initial.flags else { return false }
            let custom = try resolve(#"[{"command":"markThreadUnread","key":"Control+Option+K"}]"#)
            guard custom.keyCode == 40, custom.flags == [.maskControl, .maskAlternate],
                  rejects(#"[{"command":"markThreadUnread","key":null}]"#),
                  rejects(#"[{"command":"markThreadUnread","key":"Shift+U"}]"#),
                  rejects(#"[{"command":"markThreadUnread","key":"Cmd+K Cmd+U"}]"#),
                  rejects(#"[{"command":"markThreadUnread","key":"Unknown+U"}]"#),
                  rejects(#"[{"command":"markThreadUnread","key":"Command+Shift+U"},{"command":"newTask","key":"Cmd+Shift+U"}]"#),
                  rejects(#"[{"command":"markThreadUnread","key":"Cmd+K"},{"command":"other","key":"Cmd+K Cmd+U"}]"#),
                  rejects(#"[{"command":"markThreadUnread"}]"#), rejects("invalid") else { return false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TouchBarKeymap-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("keybindings.json")
            let reader = DesktopKeybindings(url: url)
            guard try reader.unreadShortcut(lookup: lookup).flags == initial.flags else { return false }
            try Data(#"[{"command":"markThreadUnread","key":"Control+Option+K"}]"#.utf8).write(to: url)
            guard try reader.unreadShortcut(lookup: lookup).flags == custom.flags else { return false }
            try Data(#"[{"command":"markThreadUnread","key":null}]"#.utf8).write(to: url)
            do { _ = try reader.unreadShortcut(lookup: lookup); return false }
            catch DesktopKeybindings.BindingError.unassigned { }
            return true
        } catch { return false }
    }
}
