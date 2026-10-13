import Foundation

/// Protocol boundary checks run even where XCTest is only compiled, not executed.
enum AppServerResponseChecks {
    static func run() -> Bool {
        let limit = LineDelimitedUsageResponseParser.maximumBufferedBytes
        let response = Data(#"{"id":2,"result":{"rateLimits":{}}}"#.utf8) + Data([0x0A])
        var fragmented = LineDelimitedUsageResponseParser()
        guard fragmented.append(Data(repeating: 0x20, count: limit)) == nil,
              case .failure? = fragmented.append(Data([0x20])) else { return false }
        // A rejected frame must release the retained buffer.
        guard case .success? = fragmented.append(response) else { return false }
        var complete = LineDelimitedUsageResponseParser()
        guard case .failure? = complete.append(Data(repeating: 0x20, count: limit + 1) + Data([0x0A])) else { return false }
        // A large chunk of short notification lines is valid; the bound is per line.
        var notifications = Data()
        let notification = Data("{\"method\":\"ignored\"}\n".utf8)
        while notifications.count <= limit { notifications.append(notification) }
        notifications.append(response)
        var manyLines = LineDelimitedUsageResponseParser()
        guard case .success? = manyLines.append(notifications) else { return false }
        print("App-server response self-test passed (fragmented/complete overflow, buffer release, large multi-line chunk)")
        return true
    }
}
