import XCTest
@testable import CodexContextHelper

final class TaskSnapshotTests: XCTestCase {
    func testAgentTokenSummaryShowsCoverageAndRejectsOverflow() {
        let task = TaskSummary(id: "one", title: "One", updatedAt: Date())
        let context = ContextSnapshot(latestResponse: counters(50), cumulative: counters(1000), modelContextWindow: 100_000)!
        let available = TaskSnapshot(task: task, context: .available(context, DataProvenance(source: .sessionLog, schemaVersion: "fixture")))
        let missing = TaskSnapshot(task: TaskSummary(id: "two", title: "Two", updatedAt: Date()))
        let partial = AgentDiscoverySnapshot(rootID: "parent", tasks: [available, missing], exhaustive: true)
        XCTAssertEqual(partial.totalTokens, 1000)
        XCTAssertEqual(partial.coverageNote, " · 1/2 reporting")
        XCTAssertNil(AgentDiscoverySnapshot(rootID: "parent", tasks: [missing], exhaustive: true).totalTokens)
        let hugeContext = ContextSnapshot(latestResponse: counters(1), cumulative: counters(Int64.max), modelContextWindow: 100_000)!
        let huge = TaskSnapshot(task: missing.task, context: .available(hugeContext, DataProvenance(source: .sessionLog, schemaVersion: "fixture")))
        XCTAssertNil(AgentDiscoverySnapshot(rootID: "parent", tasks: [available, huge], exhaustive: true).totalTokens)
    }
    private func counters(_ total: Int64) -> TokenCounters {
        TokenCounters(input: total, cachedInput: total / 2, output: 0, reasoningOutput: 0, total: total)!
    }

    func testOccupancyUsesLatestResponseAndKeepsCumulativeSeparate() {
        let snapshot = ContextSnapshot(latestResponse: counters(250), cumulative: counters(8_000), modelContextWindow: 1_000)!
        XCTAssertEqual(snapshot.usedPercentage, 25)
        XCTAssertEqual(snapshot.remainingPercentage, 75)
        XCTAssertEqual(snapshot.remainingTokens, 750)
        XCTAssertEqual(snapshot.cumulative.total, 8_000)
        XCTAssertEqual(snapshot.latestResponse.cachedInput, 125)
        XCTAssertEqual(snapshot.measurement, .exact)
    }

    func testPercentagesBoundedAndComplementary() {
        for total: Int64 in [0, 100, 1_000, Int64.max] {
            let snapshot = ContextSnapshot(latestResponse: counters(total), cumulative: counters(total), modelContextWindow: 1_000)!
            XCTAssertTrue((0...100).contains(snapshot.usedPercentage))
            XCTAssertEqual(snapshot.usedPercentage + snapshot.remainingPercentage, 100)
        }
    }

    func testCodexEstimateReservesBaselineAndClampsWithoutOverflow() {
        for (total, expectedRemaining): (Int64, Int) in [(0, 100), (12_000, 100), (56_000, 50), (99_000, 1), (100_000, 0), (Int64.max, 0)] {
            let snapshot = ContextSnapshot(latestResponse: counters(total), cumulative: counters(Int64.max), modelContextWindow: 100_000)!
            XCTAssertEqual(snapshot.estimatedRemainingPercentage, expectedRemaining)
            XCTAssertEqual(snapshot.estimatedUsedPercentage + snapshot.estimatedRemainingPercentage, 100)
        }
        let tiny = ContextSnapshot(latestResponse: counters(0), cumulative: counters(0), modelContextWindow: 12_000)!
        XCTAssertEqual(tiny.estimatedRemainingPercentage, 0, "Matches Codex's below-baseline boundary")
        let huge = ContextSnapshot(latestResponse: counters(Int64.max), cumulative: counters(Int64.max), modelContextWindow: Int64.max)!
        XCTAssertEqual(huge.estimatedRemainingPercentage, 0)
    }

    func testCodexEstimateUsesWholePercentRounding() {
        let snapshot = ContextSnapshot(latestResponse: counters(61_500), cumulative: counters(500_000), modelContextWindow: 112_000)!
        XCTAssertEqual(snapshot.estimatedRemainingPercentage, 51)
        XCTAssertEqual(snapshot.estimatedUsedPercentage, 49)
    }

    func testMissingOrZeroWindowIsUnavailable() {
        XCTAssertNil(ContextSnapshot(latestResponse: nil, cumulative: counters(50), modelContextWindow: 100))
        XCTAssertNil(ContextSnapshot(latestResponse: counters(50), cumulative: counters(50), modelContextWindow: 0))
        XCTAssertNil(ContextSnapshot(latestResponse: counters(50), cumulative: counters(50), modelContextWindow: nil))
        let metric: Metric<ContextSnapshot> = .unavailable(.invalidCounters)
        XCTAssertNil(metric.value)
    }

    func testCounterValidationAndOverflow() {
        XCTAssertNil(TokenCounters(input: -1, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0))
        XCTAssertNil(TokenCounters(input: 2, cachedInput: 3, output: 0, reasoningOutput: 0, total: 2))
        XCTAssertNil(counters(Int64.max).adding(counters(1)))
        XCTAssertEqual(counters(100).adding(counters(100))?.total, 200)
    }

    func testFreshnessCrossesBoundaryWithoutLosingValue() {
        let time = Date(timeIntervalSince1970: 1_000)
        let source = DataProvenance(source: .sessionLog, schemaVersion: "fixture-1", observedAt: time)
        XCTAssertFalse(source.isStale(at: time.addingTimeInterval(60)))
        XCTAssertTrue(source.isStale(at: time.addingTimeInterval(61)))
    }

    func testCalendarWeekUsesMondayAndReportsMissingDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let usage = WeekToDateUsage.calculate(days: [
            DailyTokenUsage(day: "2026-09-06", tokens: 500),
            DailyTokenUsage(day: "2026-09-07", tokens: 100),
            DailyTokenUsage(day: "2026-09-09", tokens: 300)
        ], now: now, calendar: calendar)
        XCTAssertEqual(usage.tokens, 400)
        XCTAssertEqual(usage.includedDays, 2)
        XCTAssertEqual(usage.expectedDays, 4)
        XCTAssertFalse(usage.isComplete)
    }

    func testGregorianServerDaysIgnorePreferredCalendarAndPreserveTimeZone() {
        // Tuesday in UTC and GMT+9, but still Monday in GMT-7.
        let now = ISO8601DateFormatter().date(from: "2026-09-08T02:00:00Z")!
        let days = [
            DailyTokenUsage(day: "2026-09-06", tokens: 5_000),
            DailyTokenUsage(day: "2026-09-07", tokens: 100),
            DailyTokenUsage(day: "2026-09-08", tokens: 200),
            DailyTokenUsage(day: "2026-09-09", tokens: 3_000)
        ]
        for identifier in [Calendar.Identifier.buddhist, .hebrew] {
            for (offsetHours, expectedDays, expectedTokens) in [(-7, 1, Int64(100)), (9, 2, Int64(300))] {
                var preferredCalendar = Calendar(identifier: identifier)
                preferredCalendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)!
                let usage = WeekToDateUsage.calculate(days: days, now: now, calendar: preferredCalendar)
                XCTAssertEqual(usage.tokens, expectedTokens, "\(identifier), GMT\(offsetHours)")
                XCTAssertEqual(usage.includedDays, expectedDays)
                XCTAssertEqual(usage.expectedDays, expectedDays)
                XCTAssertTrue(usage.isComplete)
            }
        }
    }
}
