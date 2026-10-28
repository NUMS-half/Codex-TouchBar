#if canImport(XCTest)
import XCTest
@testable import CodexTouchBar

final class SessionTPSTests: XCTestCase {
    func testPerTurnModelThroughput() throws { try SessionTPSChecks.calculator() }
    func testCapacityAndIntervalOrdering() throws { try SessionTPSChecks.capacityAndIntervalOrder() }
    func testIndependentLifetimeCarriersAndCompletion() throws { try SessionTPSChecks.independentCarriers() }
    func testBoundedIPCFrames() throws { try SessionTPSChecks.frames() }
    func testIncrementalAndUntrustedFiles() throws { try SessionTPSChecks.reader() }
    @MainActor func testRevisitingCachedConversations() async throws { try await SessionSelectionChecks.run() }
    func testReadOnlyThreadIndex() throws { try SessionTPSChecks.index() }
}
#endif
