import XCTest
@testable import CodexContextHelper

final class ThreadLineageResolverTests: XCTestCase {
    func testNestedDeduplicatedRollupHasSeparateMetricCoverage() {
        let root = TaskSummary(id: "root", title: "Root", updatedAt: Date())
        let child = TaskSummary(id: "child", title: "Child", updatedAt: Date(), parentThreadID: "root")
        let nested = TaskSummary(id: "nested", title: "Nested", updatedAt: Date(), parentThreadID: "child")
        let counters = TokenCounters(input: 80, cachedInput: 20, output: 20, reasoningOutput: 5, total: 100)!
        let context = ContextSnapshot(latestResponse: counters, cumulative: counters, modelContextWindow: 1000)!
        let source = DataProvenance(source: .sessionLog, schemaVersion: "fixture")
        let contexts = Dictionary(uniqueKeysWithValues: ["root", "child", "nested"].map { ($0, Metric.available(context, source)) })
        let costs = ["root": Metric.available(TaskCostEstimate(threadID: "root", creditMicros: 1_000_001, usdMicros: nil)!, source),
                     "child": Metric.available(TaskCostEstimate(threadID: "child", creditMicros: 2_000_002, usdMicros: 50)!, source)]
        let rollup = ThreadLineageResolver.rollup(root: root, lineage: ThreadLineage(tasks: [root, child, nested, child], exhaustive: true), contexts: contexts, costs: costs, costIsThreadLocal: true)
        XCTAssertEqual(rollup.threadIDs.count, 3)
        XCTAssertEqual(rollup.tokens.metric.value?.total, 300)
        XCTAssertTrue(rollup.tokens.coverage.isComplete)
        XCTAssertEqual(rollup.creditMicros.metric.value, 3_000_003)
        XCTAssertEqual(rollup.creditMicros.coverage.included, 2)
        XCTAssertEqual(rollup.usdMicros.coverage.included, 1)
        XCTAssertFalse(rollup.creditMicros.coverage.isComplete)
        let unverified = ThreadLineageResolver.rollup(root: root, lineage: ThreadLineage(tasks: [root, child], exhaustive: false), contexts: contexts, costs: costs)
        XCTAssertEqual(unverified.creditMicros.metric.unavailableReason, .unsupportedInclusiveCost)
        XCTAssertEqual(unverified.tokens.metric.value?.total, 200)
        XCTAssertFalse(unverified.tokens.coverage.isComplete)
    }
    func testUnrelatedCyclesAndOverflowNeverProduceCompleteTotal() {
        let root = TaskSummary(id: "root", title: "Root", updatedAt: Date())
        let other = TaskSummary(id: "other", title: "Other", updatedAt: Date(), parentThreadID: "other")
        let rollup = ThreadLineageResolver.rollup(root: root, lineage: ThreadLineage(tasks: [other], exhaustive: true), contexts: [:], costs: [:])
        XCTAssertEqual(rollup.threadIDs, ["root"])
        XCTAssertFalse(rollup.tokens.coverage.isComplete)
        XCTAssertNil(rollup.tokens.metric.value)
    }
}
