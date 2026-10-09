import Foundation

enum SelfTest {
    static func run() -> Bool {
        guard DesktopKeybindingChecks.run() else { return false }
        guard TouchBarConfigurationChecks.run() else { return false }
        guard CodexExecutableResolver().resolve() != nil else { return false }
        let currentBundledCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        if FileManager.default.isExecutableFile(atPath: currentBundledCodex),
           CodexExecutableResolver().resolve()?.path != currentBundledCodex {
            return false
        }
        let date = Date(timeIntervalSince1970: 1_000)

        let reversed: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 17, "windowDurationMins": 10_080],
                "secondary": ["usedPercent": 66, "windowDurationMins": 300],
            ],
        ]
        guard let first = try? UsageSnapshotParser.parse(result: reversed, now: date),
              first.fiveHour?.remainingPercent == 34,
              first.weekly?.remainingPercent == 83 else { return false }

        let multiBucket: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 40, "windowDurationMins": 10_080],
                    "credits": ["unlimited": true],
                ],
            ],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [
                    ["status": "available", "resetType": "codexRateLimits", "expiresAt": 1_500],
                    ["status": "available", "resetType": "codexRateLimits", "expiresAt": 1_200],
                ],
            ],
        ]
        guard let second = try? UsageSnapshotParser.parse(result: multiBucket, now: date),
              second.fiveHour == nil,
              second.weekly?.remainingPercent == 60,
              second.unlimitedCredits,
              second.availableResetCredits == 2,
              second.earliestAvailableResetExpiry == Date(timeIntervalSince1970: 1_200) else { return false }

        let unknown: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 1_440]],
        ]
        guard let third = try? UsageSnapshotParser.parse(result: unknown, now: date),
              third.fiveHour == nil, third.weekly == nil else { return false }

        let contentWidth = TouchBarLayout.width
        let compactCardWidth = TouchBarLayout.compactQuotaWidth(for: contentWidth)
        let actionWidth = TouchBarLayout.actionWidth(for: contentWidth)
        let navigationWidth = TouchBarLayout.navigationControlWidth(for: contentWidth)
        guard TouchBarLayout.closeWidth == 36,
              compactCardWidth == 160,
              compactCardWidth * 2 + TouchBarLayout.elementGap == contentWidth / 2,
              actionWidth == 68,
              navigationWidth == actionWidth,
              navigationWidth / 2 == 34,
              contentWidth / 2 - TouchBarLayout.actionInset
                  - 3 * actionWidth - 3 * TouchBarLayout.elementGap - navigationWidth
                  == TouchBarLayout.navigationTrailingInset,
              abs(TouchBarLayout.actionCount * actionWidth
                  + (TouchBarLayout.actionCount - 1) * TouchBarLayout.elementGap
                  + TouchBarLayout.actionInset + TouchBarLayout.navigationTrailingInset
                  - contentWidth / 2) < 0.001,
              TouchBarLayout.actionInset == TouchBarLayout.elementGap,
              DesktopMenuAction.newChat.matches(menuTitle: "新聊天"),
              DesktopMenuAction.newChat.matches(topLevelTitle: "文件"),
              DesktopMenuAction.toggleSidebar.matches(menuTitle: "显示/隐藏侧边栏"),
              DesktopMenuAction.toggleSidebar.matches(topLevelTitle: "视图"),
              DesktopMenuAction.settings.matches(menuTitle: "设置…"),
              DesktopMenuAction.back.matches(menuTitle: "Back"),
              DesktopMenuAction.forward.matches(menuTitle: "前进"),
              !DesktopMenuAction.back.matches(menuTitle: "Browser Back"),
              UsageWindow(kind: .fiveHour, usedPercent: 100, durationMinutes: 300, resetsAt: nil).remainingPercent == 0,
              UsageWindow(kind: .weekly, usedPercent: 0, durationMinutes: 10_080, resetsAt: nil).remainingPercent == 100,
              formatShortCountdown(date.addingTimeInterval(8 * 86_400 + 23 * 3_600), now: date) == "8天23时",
              SnapshotFreshness.cached.isStale,
              SnapshotFreshness.stale("offline").isStale,
              !SnapshotFreshness.live.isStale else { return false }

        var reader = LineDelimitedUsageResponseParser()
        let notification = #"{"method":"account/rateLimits/updated","params":{}}"# + "\n"
        let response = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"# + "\n"
        guard reader.append(Data((notification + response.prefix(20)).utf8)) == nil,
              case let .success(responseData)? = reader.append(Data(response.dropFirst(20).utf8)),
              (try? UsageSnapshotParser.parse(data: responseData, now: date).fiveHour?.remainingPercent) == 99 else {
            return false
        }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-touchbar-self-test-\(UUID().uuidString).json")
        let cache = UsageCache(fileURL: cacheURL, now: { date.addingTimeInterval(86_401) })
        cache.save(first)
        let isExpired = cache.loadIfFresh() == nil
        try? FileManager.default.removeItem(at: cacheURL)
        return isExpired
    }
}

/// These checks also run on Command Line Tools installations without an
/// executable XCTest runtime.
enum TouchBarConfigurationChecks {
    static func run() -> Bool {
        let additions = TouchBarConfiguration(slots: [
            .init(action: .command(.builtIn(.temporaryChat))),
            .init(action: .command(.builtIn(.markUnread))),
        ])
        guard TouchBarConfiguration.decode(additions.encoded()) == additions,
              additions.slots[0].buttonTitle == "临时聊天", additions.slots[1].buttonTitle == "标记未读",
              DesktopMenuAction.temporaryChat.matches(menuTitle: "新建临时聊天"),
              DesktopMenuAction.temporaryChat.matches(topLevelTitle: "File"),
              !DesktopMenuAction.temporaryChat.matches(menuTitle: "New Chat") else { return false }
        // General macOS editing/window commands must never become candidates
        // or survive as a configurable ChatGPT-only action.
        for (category, title) in [(DesktopMenuCategory.edit, "Copy"), (.edit, "Paste"), (.edit, "Select All"), (.view, "Zoom In"), (.view, "Toggle Full Screen")] {
            let command = DesktopCommand.native(.init(category: category, title: title, identifier: nil))
            guard !command.isValid else { return false }
            let slots = [TouchBarSlotConfiguration(action: .command(command))] + Array(TouchBarConfiguration.defaultSlots.dropFirst())
            guard TouchBarConfiguration(slots: slots) == .default else { return false }
        }
        let native = NativeMenuCommand(category: .view, title: "Search Chats…", identifier: "search-chats")
        let slot = TouchBarSlotConfiguration(action: .command(.native(native)), customLabel: " 搜索 ")
        let configuration = TouchBarConfiguration(slots: [slot, slot, .init(action: .navigationPair), slot])
        guard TouchBarConfiguration.decode(configuration.encoded()) == configuration,
              configuration.slots[0].buttonTitle == "搜索",
              TouchBarConfiguration.decode(nil) == .default,
              TouchBarConfiguration.decode(Data("invalid".utf8)) == .default,
              TouchBarConfiguration.decode(Data(#"{"version":2,"slots":[]}"#.utf8)) == .default,
              native.matches(title: "搜索聊天", identifier: "search-chats"),
              !native.matches(title: "Search Chats…", identifier: "other"),
              !native.matches(title: "Search Chats…", identifier: nil) else { return false }
        let titleOnly = NativeMenuCommand(category: .view, title: "Search Files…", identifier: nil)
        guard titleOnly.matches(title: "Search Files…", identifier: nil),
              !titleOnly.matches(title: "Search Files More…", identifier: nil),
              ChatGPTMenuCommands.displayName(category: .view, title: "搜索聊天…") == "搜索聊天",
              ChatGPTMenuCommands.displayName(category: .help, title: "Keyboard Shortcuts") == "快捷键设置",
              ChatGPTMenuCommands.displayName(category: .edit, title: "Find") == nil,
              var record = configuration.encoded().flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              var values = record["slots"] as? [Any] else { return false }
        let legacy = TouchBarSlotConfiguration(action: .command(.native(.init(category: .edit, title: "Copy", identifier: "copy"))))
        guard let legacyData = try? JSONEncoder().encode(legacy),
              let legacyValue = try? JSONSerialization.jsonObject(with: legacyData) else { return false }
        values[1] = legacyValue
        record["slots"] = values
        guard let legacyRecord = try? JSONSerialization.data(withJSONObject: record),
              TouchBarConfiguration.decode(legacyRecord).slots[1] == TouchBarConfiguration.defaultSlots[1],
              TouchBarConfiguration.decode(legacyRecord).slots[0] == configuration.slots[0] else { return false }
        values[1] = ["action": ["obsolete": [:]]]
        record["slots"] = values
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return false }
        let recovered = TouchBarConfiguration.decode(data)
        return recovered.slots[1] == TouchBarConfiguration.defaultSlots[1]
            && recovered.slots[0] == configuration.slots[0]
            && recovered.slots[2] == configuration.slots[2]
            && recovered.slots[3] == configuration.slots[3]
    }
}
