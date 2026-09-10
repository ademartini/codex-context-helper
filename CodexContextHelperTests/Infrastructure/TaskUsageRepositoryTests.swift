import XCTest
@testable import CodexContextHelper

private actor CostFixtureProvider: TaskCostProviding {
    var calls = 0
    func taskCost(threadID: String) async -> Metric<TaskCostEstimate> {
        calls += 1
        let call = calls
        if call == 1 { try? await Task.sleep(for: .milliseconds(150)) }
        let value = TaskCostEstimate(threadID: threadID, creditMicros: Int64(call), usdMicros: nil)!
        return .available(value, DataProvenance(source: .appServer, schemaVersion: "fixture", measurement: .backendEstimated))
    }
}
private struct MissingCostProvider: TaskCostProviding {
    func taskCost(threadID: String) async -> Metric<TaskCostEstimate> { .unavailable(.disconnected) }
}
final class TaskUsageRepositoryTests: XCTestCase, @unchecked Sendable {
    func testCacheRemainsBoundedWhenRequestContainsMoreThanTwoHundredIDs() async {
        let repository = TaskUsageRepository(), provider = CostFixtureProvider()
        _ = await repository.refresh(ids: (0..<200).map(String.init), using: provider)
        let result = await repository.refresh(ids: ((200..<400).map(String.init) + (0..<200).map(String.init)), using: provider)
        XCTAssertEqual(result.count, 200)
        XCTAssertNil(result["0"])
    }
    func testOlderRefreshCannotOverwriteNewerAndFailureMarksCacheStale() async {
        let repository = TaskUsageRepository(), provider = CostFixtureProvider()
        async let first = repository.refresh(ids: ["root"], using: provider)
        try? await Task.sleep(for: .milliseconds(30))
        let second = await repository.refresh(ids: ["root"], using: provider)
        let oldCompletion = await first
        XCTAssertEqual(second["root"]?.value?.creditMicros, 2)
        XCTAssertEqual(oldCompletion["root"]?.value?.creditMicros, 2)
        let stale = await repository.refresh(ids: ["root", "root"], using: MissingCostProvider())
        XCTAssertEqual(stale["root"]?.value?.creditMicros, 2)
        XCTAssertEqual(stale["root"]?.provenance?.isStale(), true)
    }
}
