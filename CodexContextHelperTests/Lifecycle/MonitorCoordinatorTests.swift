import XCTest
@testable import CodexContextHelper

private actor FixtureBackend: MonitorBackend {
    var starts = 0
    var closes = 0
    var connected = false
    var catalogReads = 0
    var accountReads = 0
    var selectedReads = 0
    var selectedDelay = 0
    var canClose = true
    var recent = [TaskSummary(id: "recent", title: "Recent task", updatedAt: Date(timeIntervalSince1970: 200))]
    var selected = TaskSummary(id: "selected", title: "Older selected task", updatedAt: Date(timeIntervalSince1970: 100))
    var matches = ThreadLineage(tasks: [], exhaustive: true)
    var lineage = ThreadLineage(tasks: [], exhaustive: false)
    var account = AccountUsageSnapshot(quotas: .unavailable(.signedOut), dailyTokens: .unavailable(.signedOut))
    func start() { starts += 1; connected = true }
    func close() -> Bool { closes += 1; if canClose { connected = false }; return canClose }
    func isConnected() -> Bool { connected }
    func recentTasks(count: Int) -> [TaskSummary] { catalogReads += 1; return Array(recent.prefix(count)) }
    func selectedTask(id: String) async -> TaskSummary {
        selectedReads += 1
        if selectedDelay > 0 { try? await Task.sleep(for: .milliseconds(selectedDelay)) }
        return selected
    }
    func setSelected(_ value: TaskSummary, delay: Int = 0) { selected = value; selectedDelay = delay }
    func matchingTitle(_ title: String) -> ThreadLineage { matches }
    func accountUsage() -> AccountUsageSnapshot { accountReads += 1; return account }
    func descendants(rootID: String) -> ThreadLineage { lineage }
    func setLineage(_ value: ThreadLineage) { lineage = value }
    func taskCost(threadID: String) -> Metric<TaskCostEstimate> { .unavailable(.noData) }
    func failWithoutStopping() { connected = false; canClose = false }
    func allowClose() { canClose = true }
    func setMatches(_ value: ThreadLineage) { matches = value }
    func setRecent(_ value: [TaskSummary]) { recent = value }
}

@MainActor
final class MonitorCoordinatorTests: XCTestCase {
    func testAgentListExcludesRootAndClearsWhenMonitoringHidden() async {
        let backend = FixtureBackend(), model = model()
        let root = TaskSummary(id: "recent", title: "Root", updatedAt: Date())
        let child = TaskSummary(id: "agent", title: "Review", updatedAt: Date(), parentThreadID: root.id)
        await backend.setLineage(ThreadLineage(tasks: [root, child], exhaustive: true))
        model.settings.includeSubagents = true
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await settle {
            await coordinator.poll(now: Date().addingTimeInterval(5))
            return model.agentDiscovery?.tasks.count == 1
        }
        XCTAssertEqual(model.agentDiscovery?.tasks.map(\.id), [child.id])
        XCTAssertEqual(model.agentDiscovery?.rootID, root.id)
        XCTAssertEqual(model.agentDiscovery?.exhaustive, true)
        model.settings.includeSubagents = false
        model.panelVisible = false
        coordinator.preferencesChanged()
        XCTAssertNil(model.agentDiscovery)
        XCTAssertNil(model.agentDiscovery?.rootID)
        _ = await coordinator.stop()
    }
    private func model(approved: Bool = true) -> PanelViewModel {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.lifecycle.\(UUID().uuidString)")!))
        if approved { model.settings.approvedExecutable = ApprovedExecutable(path: "/fixture", identity: "fixture", version: "0.153.4") }
        return model
    }
    private func settle(_ condition: () async -> Bool) async {
        for _ in 0..<600 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Lifecycle did not reach the expected state")
    }
    func testNoBackendBeforeApprovalAndSingleConnectionAcrossPolls() async {
        let backend = FixtureBackend(), model = model(approved: false)
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        await coordinator.poll()
        let before = await backend.starts
        XCTAssertEqual(before, 0); XCTAssertEqual(model.connectionIssue, .unapprovedExecutable)
        model.settings.approvedExecutable = ApprovedExecutable(path: "/fixture", identity: "fixture", version: "0.153.4")
        coordinator.executableApproved()
        await coordinator.poll()
        await settle { await backend.starts == 1 }
        for _ in 0..<5 { await coordinator.poll() }
        let starts = await backend.starts
        XCTAssertEqual(starts, 1)
        let stopped = await coordinator.stop(); XCTAssertTrue(stopped)
    }
    func testOffRecentExactSelectionKeepsRecentOrderingAndSignedOutState() async {
        let backend = FixtureBackend(), model = model()
        model.trackingMode = .codex
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await coordinator.poll()
        await settle { model.selection.threadID == "selected" && model.tasks.count == 2 && model.connectionIssue == .signedOut }
        XCTAssertEqual(model.selection.provenance, .exact)
        XCTAssertEqual(model.tasks.first?.id, "recent")
        XCTAssertEqual(model.selectedTask?.task.title, "Older selected task")
        coordinator.refresh(); await coordinator.poll()
        await settle { model.connectionIssue == .signedOut }
        XCTAssertEqual(model.account.quotas.unavailableReason, .signedOut)
        _ = await coordinator.stop()
    }
    func testNonExhaustiveTitleMatchNeverClaimsExact() async {
        let backend = FixtureBackend(), model = model()
        model.trackingMode = .codex
        let candidate = TaskSummary(id: "selected", title: "Duplicate", updatedAt: Date())
        await backend.setMatches(ThreadLineage(tasks: [candidate], exhaustive: false))
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .selected(ids: [], titles: ["Duplicate"]) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await coordinator.poll()
        await settle { model.selection.threadID == "recent" }
        XCTAssertEqual(model.selection.provenance, .inferred(.ambiguousSelection))
        _ = await coordinator.stop()
    }
    func testUnverifiedChildShutdownPreventsReplacement() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await backend.failWithoutStopping()
        await coordinator.poll()
        await coordinator.poll(now: Date().addingTimeInterval(60))
        let starts = await backend.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(model.connectionIssue, .disconnected)
        await backend.allowClose(); _ = await coordinator.stop()
    }
    func testPinnedTaskSurvivesNewCatalogActivityThenCanFollowLatest() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
        model.onTaskTrackingChange = { coordinator.taskTrackingChanged() }
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await settle { await coordinator.poll(); return model.selectedTask?.id == "recent" }
        XCTAssertEqual(model.selection.provenance, .latest, "Latest mode does not follow an unrelated AX selection")
        model.track(.pinned("recent"))
        await backend.setSelected(TaskSummary(id: "recent", title: "Pinned task refreshed", updatedAt: Date(), activity: .completed))
        let new = TaskSummary(id: "new", title: "New", updatedAt: Date().addingTimeInterval(60))
        await backend.setRecent([new])
        coordinator.refresh(); await coordinator.poll()
        await settle { model.tasks.first?.id == "new" }
        await coordinator.poll(now: Date().addingTimeInterval(5))
        XCTAssertEqual(model.selectedTask?.id, "recent")
        XCTAssertEqual(model.selection.provenance, .pinned)
        XCTAssertEqual(model.selectedTask?.task.title, "Pinned task refreshed")
        XCTAssertEqual(model.selectedTask?.task.activity, .completed)
        model.track(.latest)
        await coordinator.poll(now: Date().addingTimeInterval(10))
        await settle { model.selectedTask?.id == "new" }
        XCTAssertFalse(model.tasks.contains { $0.id == "recent" })
        _ = await coordinator.stop()
    }
    func testLateCodexLookupCannotReplaceNewlyPinnedTask() async {
        let backend = FixtureBackend(), model = model()
        await backend.setSelected(TaskSummary(id: "selected", title: "Old Codex selection", updatedAt: Date()), delay: 250)
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
        model.onTaskTrackingChange = { coordinator.taskTrackingChanged() }
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await settle { await coordinator.poll(); return model.selectedTask?.id == "recent" }
        model.track(.codex)
        await coordinator.poll()
        await settle { await backend.selectedReads > 0 }
        model.track(.pinned("recent"))
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.selectedTask?.id, "recent")
        XCTAssertEqual(model.selection.provenance, .pinned)
        await coordinator.poll(now: Date().addingTimeInterval(3))
        XCTAssertEqual(model.selectedTask?.id, "recent")
        XCTAssertEqual(model.selection.provenance, .pinned)
        _ = await coordinator.stop()
    }
    func testBackoffCapsAndResets() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<8).map { _ in backoff.failed() }, [1, 2, 4, 8, 16, 30, 30, 30])
        backoff.reset(); XCTAssertEqual(backoff.failed(), 1)
    }

    func testCatalogRefreshesEveryFiveSecondsAndAccountEveryThirty() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        let start = Date()
        await coordinator.poll(now: start); await settle { await backend.starts == 1 }
        await coordinator.poll(now: start)
        await settle { await backend.catalogReads == 1 }
        await settle { await backend.accountReads == 1 }
        await coordinator.poll(now: start.addingTimeInterval(5))
        await settle { await backend.catalogReads == 2 }
        let accountAtFive = await backend.accountReads
        XCTAssertEqual(accountAtFive, 1)
        await coordinator.poll(now: start.addingTimeInterval(30))
        await settle { await backend.accountReads == 2 }
        _ = await coordinator.stop()
    }

    func testPersistedCounterUpdatesPresentationWithinTwoSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let file = root.appendingPathComponent("task.jsonl")
        try FileManager.default.copyItem(at: fixture, to: file)
        let backend = FixtureBackend(), model = model()
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Fixture", updatedAt: Date(), sessionPath: file.path)])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
                                             factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 }
        let appended = #"{"timestamp":"2026-09-10T12:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":300},"total_token_usage":{"input_tokens":8000,"cached_input_tokens":6000,"output_tokens":2100,"reasoning_output_tokens":300,"total_tokens":10100},"model_context_window":1000}}}"# + "\n"
        guard case .counters = try SessionLogSchema.decode(Data(appended.utf8)) else {
            return XCTFail("The appended fixture must be a recognized counter record")
        }
        let start = ContinuousClock.now
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(appended.utf8)); try handle.close()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let stopped = await coordinator.stop(); XCTAssertTrue(stopped)
    }
}
