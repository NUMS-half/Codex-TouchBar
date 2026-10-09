#if canImport(XCTest)
import Foundation
import CoreGraphics
import XCTest
@testable import CodexTouchBar

final class DesktopKeybindingTests: XCTestCase {
    private let lookup: DesktopShortcut.KeyLookup = { key in
        ["u": CGKeyCode(32), "k": 40][key].map { ($0, []) }
    }

    func testUnreadDefaultAndCustomizedBinding() throws {
        let initial = try DesktopKeybindings.resolveUnread(data: nil, lookup: lookup)
        XCTAssertEqual(initial.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(initial.keyCode, 32)
        let data = Data(#"[{"command":"markThreadUnread","key":"Control+Option+K"}]"#.utf8)
        let custom = try DesktopKeybindings.resolveUnread(data: data, lookup: lookup)
        XCTAssertEqual(custom.flags, [.maskControl, .maskAlternate])
        XCTAssertEqual(custom.keyCode, 40)
    }

    func testClearedInvalidAndConflictingBindingsNeverFallBackToDefault() {
        for json in [
            #"[{"command":"markThreadUnread","key":null}]"#,
            #"[{"command":"markThreadUnread","key":"Shift+U"}]"#,
            #"[{"command":"markThreadUnread","key":"Command+K Command+U"}]"#,
            #"[{"command":"markThreadUnread","key":"Command+K"},{"command":"newTask","key":"Cmd+K"}]"#,
            #"[{"command":"markThreadUnread"}]"#,
            "invalid",
        ] {
            XCTAssertThrowsError(try DesktopKeybindings.resolveUnread(data: Data(json.utf8), lookup: lookup))
        }
    }

    func testTemporaryChatUsesNativeFileMenuAndDoesNotMatchNormalChat() {
        XCTAssertTrue(DesktopMenuAction.temporaryChat.matches(topLevelTitle: "File"))
        XCTAssertTrue(DesktopMenuAction.temporaryChat.matches(menuTitle: "New Temporary Chat"))
        XCTAssertTrue(DesktopMenuAction.temporaryChat.matches(menuTitle: "新建临时聊天"))
        XCTAssertFalse(DesktopMenuAction.temporaryChat.matches(menuTitle: "New Chat"))
        XCTAssertFalse(DesktopMenuAction.markUnread.matches(menuTitle: "Mark as Unread"))
    }
}
#endif
