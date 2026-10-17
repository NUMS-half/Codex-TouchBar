#if canImport(XCTest)
import XCTest
@testable import CodexTouchBar

final class QuotaExperienceTests: XCTestCase {
    func testObservedChangesAndReminderPolicies() throws {
        try QuotaExperienceDiagnostics.run()
    }
}
#endif
