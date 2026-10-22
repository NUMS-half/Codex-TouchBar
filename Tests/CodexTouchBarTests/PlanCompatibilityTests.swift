#if canImport(XCTest)
import XCTest
@testable import CodexTouchBar

final class PlanCompatibilityTests: XCTestCase {
    func testServerWindowsAndUnknownResetCounts() throws { try PlanCompatibilityDiagnostics.parsing() }
    func testFamilyNamesAndDetailRequestConditions() throws { try PlanCompatibilityDiagnostics.namesAndRequests() }
    func testLegacyAndUnknownCacheCounts() throws { try PlanCompatibilityDiagnostics.cacheCompatibility() }
    func testDisappearingWindowsResetOnlyTheirAlertBaseline() throws { try PlanCompatibilityDiagnostics.windowTransitions() }
}
#endif
