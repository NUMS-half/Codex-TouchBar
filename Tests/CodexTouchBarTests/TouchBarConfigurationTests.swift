#if canImport(XCTest)
import Foundation
import XCTest
@testable import CodexTouchBar

final class TouchBarConfigurationTests: XCTestCase {
    func testCatalogOnlyAcceptsChatGPTSpecificCommands() {
        XCTAssertNotNil(ChatGPTMenuCommands.displayName(category: .view, title: "Search Chats…"))
        XCTAssertNotNil(ChatGPTMenuCommands.displayName(category: .view, title: "搜索聊天…"))
        XCTAssertNotNil(ChatGPTMenuCommands.displayName(category: .view, title: "Find"))
        XCTAssertNotNil(ChatGPTMenuCommands.displayName(category: .help, title: "Keyboard Shortcuts"))
        XCTAssertNil(ChatGPTMenuCommands.displayName(category: .edit, title: "Find"))
        for title in ["Copy", "Paste", "Undo", "Select All", "复制", "粘贴"] {
            XCTAssertFalse(DesktopCommand.native(.init(category: .edit, title: title, identifier: "system-action")).isValid)
        }
        for title in ["Zoom In", "Toggle Full Screen", "Reload", "Minimize"] {
            XCTAssertFalse(DesktopCommand.native(.init(category: .view, title: title, identifier: nil)).isValid)
        }
    }

    func testLegacyGeneralCommandFallsBackOnlyForItsSlot() throws {
        let original = TouchBarConfiguration(slots: Array(repeating: .init(action: .command(.builtIn(.forward)), customLabel: "继续"), count: 4))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original.encoded())) as? [String: Any])
        var slots = try XCTUnwrap(record["slots"] as? [Any])
        let legacy = TouchBarSlotConfiguration(action: .command(.native(.init(category: .edit, title: "Copy", identifier: "copy"))))
        slots[1] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        record["slots"] = slots
        let recovered = TouchBarConfiguration.decode(try JSONSerialization.data(withJSONObject: record))
        XCTAssertEqual(recovered.slots[1], TouchBarConfiguration.defaultSlots[1])
        for index in [0, 2, 3] { XCTAssertEqual(recovered.slots[index], original.slots[index]) }
    }

    func testConfigurationRoundTripWithDuplicateActionsAndCustomName() {
        let slot = TouchBarSlotConfiguration(action: .command(.native(.init(category: .view, title: "Search Chats…", identifier: "search-chats"))), customLabel: " 搜索 ")
        let configuration = TouchBarConfiguration(slots: [slot, slot, .init(action: .navigationPair), slot])
        XCTAssertEqual(configuration.slots[0].buttonTitle, "搜索")
        XCTAssertEqual(configuration.slots[0], configuration.slots[1])
        XCTAssertEqual(TouchBarConfiguration.decode(configuration.encoded()), configuration)
    }

    func testDamagedSlotFallsBackWithoutDiscardingOtherSlots() throws {
        let slot = TouchBarSlotConfiguration(action: .command(.builtIn(.forward)), customLabel: "继续")
        let configuration = TouchBarConfiguration(slots: [slot, slot, slot, slot])
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(configuration.encoded())) as? [String: Any])
        var slots = try XCTUnwrap(record["slots"] as? [Any])
        slots[1] = ["action": ["unknownFutureCommand": [:]]]
        record["slots"] = slots
        let recovered = TouchBarConfiguration.decode(try JSONSerialization.data(withJSONObject: record))
        XCTAssertEqual(recovered.slots[1], TouchBarConfiguration.defaultSlots[1])
        XCTAssertEqual(recovered.slots[0], slot)
        XCTAssertEqual(recovered.slots[2], slot)
        XCTAssertEqual(recovered.slots[3], slot)
    }

    func testMissingAndUnsupportedConfigurationUseDefaults() {
        XCTAssertEqual(TouchBarConfiguration.decode(nil), .default)
        XCTAssertEqual(TouchBarConfiguration.decode(Data("invalid".utf8)), .default)
        XCTAssertEqual(TouchBarConfiguration.decode(Data(#"{"version":2,"slots":[]}"#.utf8)), .default)
        XCTAssertEqual(TouchBarConfiguration(slots: []), .default)
    }

    func testNamesAreDisplayOnlyAndNavigationAlwaysKeepsArrows() {
        let command = DesktopCommand.builtIn(.newChat)
        let renamed = TouchBarSlotConfiguration(action: .command(command), customLabel: "  开始\n聊天  ").normalized
        XCTAssertEqual(renamed.buttonTitle, "开始 聊天")
        XCTAssertEqual(renamed.action, .command(command))
        XCTAssertEqual(TouchBarSlotConfiguration(action: .command(command), customLabel: "  ").buttonTitle, "＋ 新对话")
        let navigation = TouchBarSlotConfiguration(action: .navigationPair, customLabel: "其他名称").normalized
        XCTAssertNil(navigation.customLabel)
        XCTAssertEqual(navigation.buttonTitle, "←／→")
    }

    func testNativeCommandRequiresExactIdentityAndIgnoresShortcuts() {
        let command = NativeMenuCommand(category: .view, title: "Search Chats…", identifier: "search-chats")
        XCTAssertTrue(command.matches(title: "搜索聊天…", identifier: "search-chats"))
        XCTAssertFalse(command.matches(title: "Search Chats…", identifier: "search-files"))
        XCTAssertFalse(command.matches(title: "Search Chats…", identifier: nil))
        let titleOnly = NativeMenuCommand(category: .view, title: "Search Chats…", identifier: nil)
        XCTAssertTrue(titleOnly.matches(title: "Search Chats…", identifier: "new-id"))
        XCTAssertFalse(titleOnly.matches(title: "Search Chats More…", identifier: nil))
        XCTAssertFalse(titleOnly.matches(title: "Search Chats", identifier: nil))
        XCTAssertTrue(DesktopMenuCategory.view.matches("檢視"))
        XCTAssertFalse(DesktopMenuCategory.view.matches("Window"))
    }
}
#endif
