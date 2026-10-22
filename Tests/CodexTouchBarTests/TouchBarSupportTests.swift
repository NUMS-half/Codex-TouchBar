#if canImport(XCTest)
import XCTest
@testable import CodexTouchBar

final class TouchBarSupportTests: XCTestCase {
    func testDetectionSeparatesHardwareFromPresentation() throws { try TouchBarSupportChecks.detection() }
    @MainActor
    func testOptionalHardwareLifecycle() throws { try TouchBarSupportChecks.lifecycle() }
}
#endif
