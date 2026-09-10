import XCTest
@testable import CodexContextHelper

final class TaskCostEstimateTests: XCTestCase {
    func testMicrosRemainExactAndMissingUSDStaysAbsent() {
        let estimate = TaskCostEstimate(threadID: "fixture", creditMicros: Int64.max, usdMicros: nil)!
        XCTAssertEqual(estimate.creditMicros, Int64.max)
        XCTAssertEqual(estimate.credits, Decimal(string: "9223372036854.775807"))
        XCTAssertNil(estimate.estimatedUSD)
        XCTAssertEqual(estimate.measurement, .backendEstimated)
        XCTAssertEqual(TaskCostEstimate(threadID: "fixture", creditMicros: 1_250_000, usdMicros: 1)?.estimatedUSD, Decimal(string: "0.000001"))
    }

    func testNegativeEstimatesRejected() {
        XCTAssertNil(TaskCostEstimate(threadID: "fixture", creditMicros: -1, usdMicros: nil))
        XCTAssertNil(TaskCostEstimate(threadID: "fixture", creditMicros: 1, usdMicros: -1))
    }

    func testCoverageRequiresEveryMetricAndExhaustiveLineage() {
        XCTAssertTrue(RollupCoverage(included: 4, discovered: 4, lineageExhaustive: true)!.isComplete)
        XCTAssertFalse(RollupCoverage(included: 3, discovered: 4, lineageExhaustive: true)!.isComplete)
        XCTAssertFalse(RollupCoverage(included: 4, discovered: 4, lineageExhaustive: false)!.isComplete)
        XCTAssertFalse(RollupCoverage(included: 0, discovered: 0, lineageExhaustive: true)!.isComplete)
        XCTAssertNil(RollupCoverage(included: 5, discovered: 4, lineageExhaustive: true))
    }
}
