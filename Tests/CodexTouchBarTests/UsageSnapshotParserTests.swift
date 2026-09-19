#if canImport(XCTest)
import Foundation
import XCTest
@testable import CodexTouchBar

final class UsageSnapshotParserTests: XCTestCase {
    func testUsageColorBandsCoverTheirBoundaries() {
        XCTAssertEqual(UsageColorBand(remainingPercent: 0), .critical)
        XCTAssertEqual(UsageColorBand(remainingPercent: 10), .critical)
        XCTAssertEqual(UsageColorBand(remainingPercent: 11), .low)
        XCTAssertEqual(UsageColorBand(remainingPercent: 30), .low)
        XCTAssertEqual(UsageColorBand(remainingPercent: 31), .moderate)
        XCTAssertEqual(UsageColorBand(remainingPercent: 60), .moderate)
        XCTAssertEqual(UsageColorBand(remainingPercent: 61), .healthy)
        XCTAssertEqual(UsageColorBand(remainingPercent: 100), .healthy)
    }

    func testClassifiesWindowsByDurationInsteadOfPosition() throws {
        let response: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 17, "windowDurationMins": 10_080],
                "secondary": ["usedPercent": 66, "windowDurationMins": 300],
            ],
        ]
        let snapshot = try UsageSnapshotParser.parse(result: response, now: .distantPast)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 34)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 83)
    }

    func testPrefersCodexBucketAndKeepsWeeklyOnlyWindowInWeeklySlot() throws {
        let response: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 40, "windowDurationMins": 10_080],
                    "credits": ["unlimited": true],
                ],
            ],
            "rateLimitResetCredits": ["availableCount": 2],
        ]
        let snapshot = try UsageSnapshotParser.parse(result: response)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
        XCTAssertTrue(snapshot.unlimitedCredits)
        XCTAssertEqual(snapshot.availableResetCredits, 2)
    }

    func testUnknownDurationDoesNotMasqueradeAsFiveHour() throws {
        let response: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 1_440]],
        ]
        let snapshot = try UsageSnapshotParser.parse(result: response)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
    }

    func testCacheExpiresAfterTwentyFourHours() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("usage.json")
        let date = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            fiveHour: nil, weekly: nil, planType: nil, limitName: nil,
            creditBalance: nil, unlimitedCredits: false, availableResetCredits: 0, fetchedAt: date
        )
        let cache = UsageCache(fileURL: file, now: { date.addingTimeInterval(86_401) })
        cache.save(snapshot)
        XCTAssertNil(cache.loadIfFresh())
    }

    func testLineDelimitedReaderHandlesSplitResponseAndNotifications() throws {
        var reader = LineDelimitedUsageResponseParser()
        let notification = #"{"method":"account/rateLimits/updated","params":{}}"# + "\n"
        let response = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"# + "\n"
        XCTAssertNil(reader.append(Data((notification + response.prefix(20)).utf8)))
        guard case let .success(data)? = reader.append(Data(response.dropFirst(20).utf8)),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected the usage response")
        }
        XCTAssertNotNil(object["rateLimits"])
    }

    func testLineDelimitedReaderSurfacesRPCError() {
        var reader = LineDelimitedUsageResponseParser()
        let response = #"{"id":2,"error":{"message":"not signed in"}}"# + "\n"
        guard case .failure? = reader.append(Data(response.utf8)) else {
            return XCTFail("Expected the RPC error")
        }
    }
}
#endif
