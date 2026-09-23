import Foundation

enum SelfTest {
    static func run() -> Bool {
        guard CodexExecutableResolver().resolve() != nil else { return false }
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
