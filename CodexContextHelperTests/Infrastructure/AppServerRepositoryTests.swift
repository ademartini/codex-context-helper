import XCTest
@testable import CodexContextHelper

final class AppServerRepositoryTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    func testMetadataWhitelistPreservesFieldsWithoutPreviewFallback() throws {
        let page = try CodexProtocol.threadPage(fixture("thread-page"))
        XCTAssertEqual(page.nextCursor, "fixture-next")
        XCTAssertEqual(page.tasks[0].id, "root")
        XCTAssertEqual(page.tasks[0].title, "Fixture task")
        XCTAssertEqual(page.tasks[0].model, "fixture-model")
        XCTAssertEqual(page.tasks[0].activity, .active)
        XCTAssertEqual(page.tasks[0].sessionPath, "/tmp/fixture-root.jsonl")
        XCTAssertEqual(page.tasks[0].recencyAt?.timeIntervalSince1970, 1788990050)
        XCTAssertEqual(page.tasks[1].parentThreadID, "root")
        XCTAssertEqual(page.tasks[1].title, "Untitled task")
        XCTAssertFalse(String(describing: page.tasks).contains("PRIVATE_"))
    }

    func testMultipleQuotaBucketsPreferredOverLegacyAndWindowsIndependent() throws {
        let result = try XCTUnwrap(CodexProtocol.quotas(fixture("quotas")))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].windows.map(\.usedPercentage), [23, 47])
        XCTAssertEqual(result[0].windows.map(\.windowDurationMinutes), [300, 10080])
        XCTAssertNil(result[0].windows[1].resetsAt)
        XCTAssertEqual(result[1].windows[0].usedPercentage, 0)
        XCTAssertFalse(String(describing: result).contains("PRIVATE_ACCOUNT_SENTINEL"))
        let legacy: JSONValue = .object(["rateLimits": .object(["primary": .object(["usedPercent": .integer(12)])])])
        XCTAssertEqual(try CodexProtocol.quotas(legacy)?.first?.windows.first?.usedPercentage, 12)
    }

    func testMalformedQuotaWindowAndBucketPreserveOtherValues() throws {
        let value: JSONValue = .object(["rateLimitsByLimitId": .object([
            "valid": .object(["primary": .object(["usedPercent": .integer(10)]), "secondary": .object(["usedPercent": .string("bad")])]),
            "malformed": .array([])
        ])])
        let buckets = try XCTUnwrap(CodexProtocol.quotas(value))
        let valid = try XCTUnwrap(buckets.first { $0.id == "valid" })
        XCTAssertEqual(valid.windows.map(\.usedPercentage), [10])
        XCTAssertEqual(valid.unavailableWindows, ["secondary"])
        let malformed = try XCTUnwrap(buckets.first { $0.id == "malformed" })
        XCTAssertTrue(malformed.windows.isEmpty)
        XCTAssertEqual(malformed.unavailableWindows, ["primary", "secondary"])
    }

    func testDailyBucketsKeepAbsentDaysAbsentAndSummaryNullable() throws {
        let days = try XCTUnwrap(CodexProtocol.dailyUsage(fixture("daily")))
        XCTAssertEqual(days.map(\.tokens), [10, 20, 30])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        XCTAssertTrue(WeekToDateUsage.calculate(days: days, now: now, calendar: calendar).isComplete)
        let partial = WeekToDateUsage.calculate(days: [days[0], days[2]], now: now, calendar: calendar)
        XCTAssertEqual(partial.tokens, 40)
        XCTAssertFalse(partial.isComplete)
        XCTAssertNil(try CodexProtocol.dailyUsage(fixture("absent-usage")))
        XCTAssertNil(try CodexProtocol.dailyUsage(.object(["summary": .object([:])])))
    }

    func testOptionalCostPreservesExactIntegerMicrosAndNullableGroups() throws {
        let cost = try XCTUnwrap(CodexProtocol.taskCost(fixture("cost"), threadID: "root"))
        XCTAssertEqual(cost.creditMicros, 9_007_199_254_740_993)
        XCTAssertNil(cost.usdMicros)
        XCTAssertEqual(cost.groups[0].reasoningEffort, "high")
        XCTAssertEqual(cost.groups[0].speed, "fast")
        XCTAssertNil(cost.groups[0].cachedInputTokens)
        XCTAssertNil(cost.groups[0].tokenType)
        XCTAssertNil(try CodexProtocol.taskCost(fixture("absent-usage"), threadID: "root"))
        XCTAssertNil(try CodexProtocol.taskCost(.object([:]), threadID: "root"))
        XCTAssertThrowsError(try CodexProtocol.taskCost(fixture("cost"), threadID: "other"))
    }

    func testNegativeAndTypeMismatchedCountersFailClosed() throws {
        for bad: JSONValue in [.integer(-1), .string("42"), .bool(true), .number(1.5)] {
            let value: JSONValue = .object(["threadUsage": .object(["threadId": .string("root"), "estimatedUsageCreditsMicros": bad, "groups": .array([])])])
            XCTAssertThrowsError(try CodexProtocol.taskCost(value, threadID: "root"))
            XCTAssertThrowsError(try CodexProtocol.dailyUsage(.object(["dailyUsageBuckets": .array([.object(["startDate": .string("2026-09-09"), "tokens": bad])])])))
        }
        XCTAssertEqual(try CodexProtocol.quotas(.object(["rateLimits": .object(["primary": .object(["usedPercent": .integer(101)]), "secondary": .object(["usedPercent": .integer(25)])])]))?.first?.unavailableWindows, ["primary"])
        XCTAssertThrowsError(try CodexProtocol.thread(.object(["id": .string("root"), "updatedAt": .integer(-1)])))
    }

    func testSignedOutDegradesWithoutCallingUsageAndIndependentCapabilities() async {
        let signedOut = FixtureAppServer { _, _ in .object(["account": .null]) }
        let snapshot = await AppServerRepository(connection: signedOut).accountUsage()
        XCTAssertEqual(snapshot.quotas.unavailableReason, .signedOut)
        XCTAssertEqual(snapshot.dailyTokens.unavailableReason, .signedOut)
        let calls = await signedOut.calls
        XCTAssertEqual(calls.count, 1)
        let active = FixtureAppServer { method, _ in
            switch method {
            case "account/read": .object(["account": .object(["type": .string("chatgpt"), "email": .string("PRIVATE_EMAIL")])])
            case "account/rateLimits/read": .object(["rateLimits": .object(["primary": .object(["usedPercent": .integer(7)])])])
            default: throw AppServerError.unsupportedMethod
            }
        }
        let partial = await AppServerRepository(connection: active).accountUsage()
        XCTAssertEqual(partial.quotas.value?.first?.windows.first?.usedPercentage, 7)
        XCTAssertEqual(partial.dailyTokens.unavailableReason, .unsupportedSchema)
    }

    func testRecentCatalogUsesInteractiveSourcesAndBoundsRequestedRows() async throws {
        let fake = FixtureAppServer { _, _ in Self.page([Self.row("one"), Self.row("two")]) }
        let tasks = try await AppServerRepository(connection: fake).recentTasks(count: 1)
        XCTAssertEqual(tasks.count, 1)
        let calls = await fake.calls
        XCTAssertEqual(calls.first?.1["sourceKinds"], .array(CodexProtocol.interactiveSourceKinds.map(JSONValue.string)))
        XCTAssertEqual(calls.first?.1["archived"], .bool(false))
    }

    func testMatchingTitleChecksBothArchiveStatesBeforeClaimingUnique() async throws {
        let fake = FixtureAppServer { method, params in
            XCTAssertEqual(method, "thread/list")
            XCTAssertEqual(params["searchTerm"], .string("Same title"))
            if params["archived"] == .bool(true) {
                return Self.page([Self.row("archived", title: "Same title")])
            }
            return Self.page([Self.row("active", title: "Same title")])
        }
        let matches = try await AppServerRepository(connection: fake).matchingTitle("Same title")
        XCTAssertEqual(matches.tasks.map(\.id), ["active", "archived"])
        XCTAssertTrue(matches.exhaustive)
        let calls = await fake.calls
        XCTAssertEqual(calls.map { $0.1["archived"] }, [.bool(false), .bool(true)])
    }

    func testMatchingTitleMarksCoverageIncompleteWhenCombinedBudgetIsExhausted() async throws {
        let fake = FixtureAppServer { _, params in
            XCTAssertEqual(params["archived"], .bool(false))
            return Self.page([Self.row("active", title: "Same title")])
        }
        let matches = try await AppServerRepository(connection: fake, maximumKnownTasks: 1).matchingTitle("Same title")
        XCTAssertEqual(matches.tasks.map(\.id), ["active"])
        XCTAssertFalse(matches.exhaustive)
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testMatchingTitleDeduplicatesIDsAcrossArchiveStates() async throws {
        let fake = FixtureAppServer { _, _ in Self.page([Self.row("shared", title: "Same title")]) }
        let matches = try await AppServerRepository(connection: fake, maximumKnownTasks: 2).matchingTitle("Same title")
        XCTAssertEqual(matches.tasks.map(\.id), ["shared"])
        XCTAssertTrue(matches.exhaustive)
    }

    func testPaginationIncludesArchivedNestedDescendantsAndDeduplicates() async throws {
        let fake = FixtureAppServer { method, params in
            if method == "thread/read" { return .object(["thread": Self.row("root")]) }
            if params["archived"] == .bool(true) { return Self.page([Self.row("nested", parent: "child")]) }
            if params["cursor"] == .string("next") { return Self.page([Self.row("child", parent: "root")]) }
            return Self.page([Self.row("child", parent: "root")], cursor: "next")
        }
        let lineage = try await AppServerRepository(connection: fake).descendants(rootID: "root")
        XCTAssertEqual(lineage.tasks.map(\.id), ["child", "nested", "root"])
        XCTAssertTrue(lineage.exhaustive)
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 4)
        for call in calls.filter({ $0.0 == "thread/list" }) {
            XCTAssertEqual(call.1["useStateDbOnly"], .bool(true))
            XCTAssertEqual(call.1["ancestorThreadId"], .string("root"))
            guard case .array(let sources) = call.1["sourceKinds"] else { return XCTFail("Missing explicit source kinds") }
            XCTAssertTrue(sources.contains(.string("subAgentThreadSpawn")))
        }
    }

    func testRejectedDescendantShapeIsCachedWithoutDisablingRecentCatalogOrAccount() async throws {
        let fake = FixtureAppServer { method, params in
            if method == "thread/read" { return .object(["thread": Self.row("root")]) }
            if method == "account/read" { return .object(["account": .object(["type": .string("chatgpt")])]) }
            if method == "account/rateLimits/read" {
                return .object(["rateLimits": .object(["primary": .object(["usedPercent": .integer(7)])])])
            }
            if method == "account/usage/read" { return .object([:]) }
            if params["ancestorThreadId"] != nil { throw AppServerError.rejectedParameters }
            XCTAssertEqual(params["useStateDbOnly"], .bool(true))
            return Self.page([Self.row("recent")])
        }
        let repository = AppServerRepository(connection: fake)
        for _ in 0..<2 {
            let descendants = try await repository.descendants(rootID: "root")
            XCTAssertFalse(descendants.exhaustive)
            XCTAssertEqual(descendants.tasks.map(\.id), ["root"])
        }
        let recent = try await repository.recentTasks(count: 10)
        XCTAssertEqual(recent.map(\.id), ["recent"])
        let account = await repository.accountUsage()
        XCTAssertEqual(account.quotas.value?.first?.windows.first?.usedPercentage, 7)
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.1["ancestorThreadId"] != nil }.count, 1)

        // A replacement connection/repository reevaluates the previously rejected shape.
        _ = try await AppServerRepository(connection: fake).descendants(rootID: "root")
        let newCalls = await fake.calls
        XCTAssertEqual(newCalls.filter { $0.1["ancestorThreadId"] != nil }.count, 2)
    }

    func testTransientDescendantFailureIsRetriedAndDoesNotWeakenReadOnlyOptions() async throws {
        let fake = FixtureAppServer { method, params in
            if method == "thread/read" { return .object(["thread": Self.row("root")]) }
            XCTAssertEqual(params["useStateDbOnly"], .bool(true))
            XCTAssertEqual(params["ancestorThreadId"], .string("root"))
            throw AppServerError.timeout
        }
        let repository = AppServerRepository(connection: fake)
        _ = try await repository.descendants(rootID: "root")
        _ = try await repository.descendants(rootID: "root")
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.0 == "thread/list" }.count, 4)
    }

    func testFailedPaginationRetainsKnownRowsAndMarksPartial() async throws {
        let fake = FixtureAppServer { method, params in
            if method == "thread/read" { return .object(["thread": Self.row("root")]) }
            if params["archived"] == .bool(true) { return Self.page([]) }
            if params["cursor"] != nil { throw AppServerError.timeout }
            return Self.page([Self.row("child", parent: "root")], cursor: "next")
        }
        let result = try await AppServerRepository(connection: fake).descendants(rootID: "root")
        XCTAssertFalse(result.exhaustive)
        XCTAssertEqual(Set(result.tasks.map(\.id)), ["root", "child"])
    }

    func testBoundAndUnrelatedLineageNeverClaimComplete() async throws {
        let fake = FixtureAppServer { method, _ in
            if method == "thread/read" { return .object(["thread": Self.row("root")]) }
            return Self.page([Self.row("child", parent: "root"), Self.row("unrelated", parent: "somewhere")], cursor: "repeat")
        }
        let result = try await AppServerRepository(connection: fake, maximumKnownTasks: 2).descendants(rootID: "root")
        XCTAssertFalse(result.exhaustive)
        XCTAssertLessThanOrEqual(result.tasks.count, 2)
        XCTAssertFalse(result.tasks.contains { $0.id == "unrelated" })
        let calls = await fake.calls
        XCTAssertLessThanOrEqual(calls.count, 3)
    }

    private static func row(_ id: String, parent: String? = nil, title: String? = nil) -> JSONValue {
        .object(["id": .string(id), "updatedAt": .integer(100), "parentThreadId": parent.map(JSONValue.string) ?? .null,
                 "name": title.map(JSONValue.string) ?? .null])
    }
    private static func page(_ rows: [JSONValue], cursor: String? = nil) -> JSONValue {
        .object(["data": .array(rows), "nextCursor": cursor.map(JSONValue.string) ?? .null])
    }
}

private actor FixtureAppServer: AppServerRequesting {
    var calls: [(String, JSONValue)] = []
    let handler: @Sendable (String, JSONValue) throws -> JSONValue
    init(handler: @escaping @Sendable (String, JSONValue) throws -> JSONValue) { self.handler = handler }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        return try handler(method, params)
    }
}
