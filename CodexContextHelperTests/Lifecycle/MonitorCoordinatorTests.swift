import XCTest
import Darwin
import SQLite3
@testable import CodexContextHelper

private actor FixtureGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        await withCheckedContinuation { continuations.append($0); entered = true }
    }
    func release() {
        let waiting = continuations; continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor FixtureAttempts {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor FixtureBackend: MonitorBackend {
    var starts = 0
    var closes = 0
    var connected = false
    var catalogReads = 0
    var accountReads = 0
    var selectedReads = 0
    var costReads = 0
    var selectedDelay = 0
    var canClose = true
    var startGate: FixtureGate?
    var descendantGates: [String: FixtureGate] = [:]
    var descendantReads: [String: Int] = [:]
    var catalogFails = false
    var recent = [TaskSummary(id: "recent", title: "Recent task", updatedAt: Date(timeIntervalSince1970: 200))]
    var selected = TaskSummary(id: "selected", title: "Older selected task", updatedAt: Date(timeIntervalSince1970: 100))
    var matches = ThreadLineage(tasks: [], exhaustive: true)
    var lineage = ThreadLineage(tasks: [], exhaustive: false)
    var account = AccountUsageSnapshot(quotas: .unavailable(.signedOut), dailyTokens: .unavailable(.signedOut))
    func start() async { starts += 1; if let startGate { await startGate.wait() }; connected = true }
    func setStartGate(_ gate: FixtureGate, canClose: Bool) { startGate = gate; self.canClose = canClose }
    func close() -> Bool { closes += 1; if canClose { connected = false }; return canClose }
    func isConnected() -> Bool { connected }
    func recentTasks(count: Int) throws -> [TaskSummary] {
        catalogReads += 1
        if catalogFails { throw NSError(domain: "Fixture", code: 1) }
        return Array(recent.prefix(count))
    }
    func setCatalogFails(_ value: Bool) { catalogFails = value }
    func selectedTask(id: String) async -> TaskSummary {
        selectedReads += 1
        if selectedDelay > 0 { try? await Task.sleep(for: .milliseconds(selectedDelay)) }
        return selected
    }
    func setSelected(_ value: TaskSummary, delay: Int = 0) { selected = value; selectedDelay = delay }
    func matchingTitle(_ title: String) -> ThreadLineage { matches }
    func accountUsage() -> AccountUsageSnapshot { accountReads += 1; return account }
    func descendants(rootID: String) async -> ThreadLineage {
        descendantReads[rootID, default: 0] += 1
        if let gate = descendantGates[rootID] { await gate.wait() }
        return lineage
    }
    func setDescendantGate(_ gate: FixtureGate, for id: String) { descendantGates[id] = gate }
    func setLineage(_ value: ThreadLineage) { lineage = value }
    func taskCost(threadID: String) -> Metric<TaskCostEstimate> { costReads += 1; return .unavailable(.noData) }
    func setAccount(_ value: AccountUsageSnapshot) { account = value }
    func failWithoutStopping() { connected = false; canClose = false }
    func allowClose() { canClose = true }
    func setMatches(_ value: ThreadLineage) { matches = value }
    func setRecent(_ value: [TaskSummary]) { recent = value }
}

@MainActor
final class MonitorCoordinatorTests: XCTestCase {
    func testUnchangedCatalogPreservesCostPollingIntervalAndActivityRefreshes() async {
        let backend = FixtureBackend(), model = model(), now = Date()
        await backend.setAccount(AccountUsageSnapshot(
            quotas: .available([], DataProvenance(source: .appServer, schemaVersion: "fixture")),
            dailyTokens: .unavailable(.noData)))
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in backend }, evidence: { .unavailable(.noData) })
        func tick(_ seconds: TimeInterval) async {
            for _ in 0..<30 {
                await coordinator.poll(now: now.addingTimeInterval(seconds))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await tick(0)
        let initial = await backend.costReads
        XCTAssertGreaterThan(initial, 0)
        await tick(6)
        let idle = await backend.costReads
        XCTAssertEqual(idle, initial, "An unchanged task list must not restart cost requests")
        await backend.setRecent([TaskSummary(id: "recent", title: "Recent task", updatedAt: now)])
        await tick(12)
        let activity = await backend.costReads
        XCTAssertGreaterThan(activity, idle, "New task activity should refresh costs promptly")
        await tick(45)
        let periodic = await backend.costReads
        XCTAssertGreaterThan(periodic, activity, "Costs should still refresh on their normal interval")
        _ = await coordinator.stop()
    }

    func testDesktopSelectionCannotUseBackendOnlyIdentity() async {
        let backend = FixtureBackend(), model = model()
        model.trackingMode = .codex
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in backend }, evidence: { .localTask("selected") })
        coordinator.start()
        await settle {
            let reads = await backend.catalogReads
            return reads > 0 && model.selection.provenance == .inferred(.missingSession)
        }
        XCTAssertNil(model.selection.threadID)
        let reads = await backend.selectedReads
        XCTAssertEqual(reads, 0)
        _ = await coordinator.stop()
    }
    func testDesktopSelectionRejectsConflictedLocalIdentityWithoutBackendFallback() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("duplicate.jsonl"))
        let backend = FixtureBackend(), model = model()
        model.trackingMode = .codex
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Remote title", updatedAt: Date(), sessionPath: file.path)])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in backend }, evidence: { .localTask("fixture-root") })
        coordinator.start()
        await settle {
            let reads = await backend.catalogReads
            return reads > 0 && model.selection.provenance == .inferred(.missingSession)
        }
        XCTAssertNil(model.selection.threadID)
        let reads = await backend.selectedReads
        XCTAssertEqual(reads, 0)
        _ = await coordinator.stop()
    }

    func testAgentListExcludesRootAndClearsWhenMonitoringHidden() async {
        let backend = FixtureBackend(), model = model()
        let root = TaskSummary(id: "recent", title: "Root", updatedAt: Date())
        let child = TaskSummary(id: "agent", title: "Review", updatedAt: Date(), parentThreadID: root.id)
        await backend.setLineage(ThreadLineage(tasks: [root, child], exhaustive: true))
        model.settings.includeSubagents = true
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
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
    private var emptyRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("fixture-missing-\(UUID().uuidString)") }

    private func model(approved: Bool = true, pinnedID: String = "recent") -> PanelViewModel {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.lifecycle.\(UUID().uuidString)")!))
        model.trackingMode = .pinned(pinnedID)
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
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
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
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
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
    func testTitleOnlyEvidenceCannotMistakeAnotherDesktopSurfaceForTask() async {
        let backend = FixtureBackend(), model = model()
        model.trackingMode = .codex
        let candidate = TaskSummary(id: "selected", title: "Duplicate", updatedAt: Date())
        await backend.setMatches(ThreadLineage(tasks: [candidate], exhaustive: true))
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .selected(ids: [], titles: ["Duplicate"]) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await coordinator.poll()
        await settle { model.selection.provenance == .inferred(.ambiguousSelection) }
        XCTAssertNil(model.selection.threadID)
        XCTAssertNil(model.selectedTask)
        _ = await coordinator.stop()
    }
    func testUnverifiedChildShutdownPreventsReplacement() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await backend.failWithoutStopping()
        await coordinator.poll()
        await coordinator.poll(now: Date().addingTimeInterval(60))
        let starts = await backend.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(model.connectionIssue, .disconnected)
        await backend.allowClose(); _ = await coordinator.stop()
    }
    func testPinnedTaskSurvivesNewCatalogActivityThenCanFollowCodexSelection() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
        model.onTaskTrackingChange = { coordinator.taskTrackingChanged() }
        await coordinator.poll(); await settle { await backend.starts == 1 }
        await settle { await coordinator.poll(); return model.selectedTask?.id == "recent" }
        XCTAssertEqual(model.selection.provenance, .pinned, "An explicit pin ignores an unrelated Codex selection")
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
        await backend.setSelected(TaskSummary(id: "selected", title: "Clicked task", updatedAt: Date(timeIntervalSince1970: 100)))
        model.track(.codex)
        await coordinator.poll(now: Date().addingTimeInterval(10))
        await settle { model.selectedTask?.id == "selected" }
        XCTAssertEqual(model.selection.provenance, .exact)
        XCTAssertFalse(model.tasks.contains { $0.id == "recent" })
        _ = await coordinator.stop()
    }
    func testLateCodexLookupCannotReplaceNewlyPinnedTask() async {
        let backend = FixtureBackend(), model = model()
        await backend.setSelected(TaskSummary(id: "selected", title: "Old Codex selection", updatedAt: Date()), delay: 250)
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .selected(ids: ["selected"], titles: []) })
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
    private func localFixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let file = root.appendingPathComponent("task.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "0.153.4", with: "0.200.1")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }
    private func assertSameFile(_ path: String?, as expected: URL) throws {
        let actual = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(path))
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: expected.path)
        XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expectedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(actual[.systemNumber] as? NSNumber, expectedAttributes[.systemNumber] as? NSNumber)
    }
    private func appendCounter(to file: URL) throws {
        let counter = #"{"timestamp":"2026-09-10T12:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":300},"total_token_usage":{"input_tokens":8000,"cached_input_tokens":6000,"output_tokens":2100,"reasoning_output_tokens":300,"total_tokens":10100},"model_context_window":1000}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(counter.utf8)); try handle.close()
    }
    func testCodexSelectionIgnoresBackgroundActivityAndClearsWhenSelectionIsUnavailable() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backgroundFile = root.appendingPathComponent("background.jsonl")
        let background = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "fixture-root", with: "fixture-background")
        try background.write(to: backgroundFile, atomically: true, encoding: .utf8)
        let model = model(approved: false)
        model.trackingMode = .codex
        var observed = TaskSelectionEvidence.selected(ids: ["fixture-root"], titles: [])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root), evidence: { observed })
        coordinator.start()
        await settle { model.selectedTask?.id == "fixture-root" && model.selectedTask?.context.value?.latestResponse.total == 250 }
        let selectedTitle = model.selectedTask?.task.title

        try appendCounter(to: backgroundFile)
        await settle {
            coordinator.refresh(); await coordinator.poll()
            return model.tasks.first { $0.id == "fixture-background" }?.context.value?.latestResponse.total == 300
        }
        XCTAssertEqual(model.selectedTask?.id, "fixture-root", "Background responses must not change the selected task")
        XCTAssertEqual(model.selectedTask?.context.value?.latestResponse.total, 250)
        XCTAssertEqual(model.selection.provenance, .exact)

        observed = .selected(ids: ["fixture-background"], titles: [])
        coordinator.refresh(); await coordinator.poll()
        await settle { model.selectedTask?.id == "fixture-background" && model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertNotEqual(model.selectedTask?.task.title, selectedTitle)
        XCTAssertEqual(model.selection.provenance, .exact)

        observed = .unavailable(.permissionDenied)
        coordinator.refresh(); await coordinator.poll()
        await settle { model.selection.provenance == .inferred(.permissionDenied) }
        XCTAssertNil(model.selection.threadID)
        XCTAssertNil(model.selectedTask, "Unavailable selection must not show another task's counters")
        XCTAssertEqual(model.tasks.count, 2, "Local tasks remain available for explicit pinning")
        _ = await coordinator.stop()
    }
    func testChangedOptionalExecutableDoesNotBlockNewerLocalSession() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(pinnedID: "fixture-root")
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in throw ExecutableError.changed }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 && model.connectionIssue == .executableChanged }
        try appendCounter(to: file)
        await settle { model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertEqual(model.connectionIssue, .executableChanged)
        XCTAssertEqual(model.selectedTask?.context.provenance?.invalidated, false)
        _ = await coordinator.stop()
    }
    func testSlowOptionalConnectionDoesNotDelayLocalContext() async throws {
        let (root, _) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(pinnedID: "fixture-root"), backend = FixtureBackend()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in try await Task.sleep(for: .milliseconds(1500)); return backend }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 }
        let starts = await backend.starts
        XCTAssertEqual(starts, 0, "Local context should arrive before the optional process starts")
        _ = await coordinator.stop()
    }
    func testRemoteEnrichmentPreservesLocalPathAndDisconnectKeepsWatcher() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(pinnedID: "fixture-root"), backend = FixtureBackend()
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Remote title", updatedAt: Date(), sessionPath: nil)])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        model.onDisconnectAccount = { coordinator.disconnectAccount() }
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 && model.selectedTask?.task.title == "Remote title" }
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)
        model.track(.pinned("fixture-root"))
        model.disconnectAccountUsage()
        await settle { await backend.closes > 0 }
        try appendCounter(to: file)
        await settle { model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertEqual(model.selection.provenance, .pinned)
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)
        _ = await coordinator.stop()
    }
    func testDesktopTitleSurvivesMissingRemoteNameExactSelectionAndAccountDisconnect() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("desktop.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(opened, "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT); INSERT INTO local_thread_catalog VALUES ('local', 'fixture-root', 'Named desktop task')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(opened), SQLITE_OK)

        let model = model(), backend = FixtureBackend()
        model.trackingMode = .codex
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Untitled task", updatedAt: Date())])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            desktopTitles: DesktopTaskTitleRepository(databaseURL: databaseURL),
            factory: { _ in backend }, evidence: { .selected(ids: ["fixture-root"], titles: []) })
        model.onDisconnectAccount = { coordinator.disconnectAccount() }
        coordinator.start()
        await settle { await backend.catalogReads > 0 }
        await settle { model.selectedTask?.task.title == "Named desktop task" && model.selectedTask?.context.value?.latestResponse.total == 250 }
        XCTAssertEqual(model.selection.provenance, .exact)
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)

        model.disconnectAccountUsage()
        await settle { await backend.closes > 0 }
        try appendCounter(to: file)
        await settle { model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertEqual(model.selectedTask?.task.title, "Named desktop task")
        XCTAssertEqual(model.selection.provenance, .exact)
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)
        _ = await coordinator.stop()
    }
    func testLocalAgentsUseExplicitParentsAndPartialCoverage() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let child = text.replacingOccurrences(of: "fixture-root", with: "fixture-child")
            .replacingOccurrences(of: "\"cli_version\":", with: "\"parent_thread_id\":\"fixture-root\",\"cli_version\":")
        try child.write(to: root.appendingPathComponent("child.jsonl"), atomically: true, encoding: .utf8)
        let model = model(approved: false, pinnedID: "fixture-root")
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in throw ExecutableError.changed }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.agentDiscovery?.tasks.first?.context.value != nil }
        XCTAssertEqual(model.selectedTask?.id, "fixture-root")
        XCTAssertEqual(model.agentDiscovery?.tasks.map(\.id), ["fixture-child"])
        XCTAssertEqual(model.agentDiscovery?.exhaustive, false)
        _ = await coordinator.stop()
    }

    func testDisconnectDuringStartRetainsChildUntilShutdownIsVerified() async {
        let model = model(), backend = FixtureBackend(), gate = FixtureGate(), attempts = FixtureAttempts()
        await backend.setStartGate(gate, canClose: false)
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in await attempts.record(); return backend }, evidence: { .unavailable(.permissionDenied) })
        model.onDisconnectAccount = { coordinator.disconnectAccount() }
        await coordinator.poll(); await settle { await gate.entered }
        model.disconnectAccountUsage()
        await gate.release()
        await settle { await backend.closes > 0 }
        model.settings.approvedExecutable = ApprovedExecutable(path: "/replacement", identity: "replacement", version: "1.0.0")
        coordinator.executableApproved()
        for _ in 0..<3 { await coordinator.poll(now: Date().addingTimeInterval(60)) }
        let factoryCalls = await attempts.count
        XCTAssertEqual(factoryCalls, 1, "An unverified child shutdown must prevent a replacement")
        await backend.allowClose(); _ = await coordinator.stop()
    }

    func testObsoleteFactoryFailureCannotOverwriteDisconnectedAccountOrDelayNewApproval() async {
        let model = model(), backend = FixtureBackend(), gate = FixtureGate(), attempts = FixtureAttempts()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in
                await attempts.record()
                if await attempts.count == 1 { await gate.wait(); throw ExecutableError.changed }
                return backend
            }, evidence: { .unavailable(.permissionDenied) })
        model.onDisconnectAccount = { coordinator.disconnectAccount() }
        await coordinator.poll(); await settle { await gate.entered }
        model.disconnectAccountUsage()
        await gate.release()
        // Drain the resumed factory task without starting another connection.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.connectionIssue, .unapprovedExecutable)
        model.settings.approvedExecutable = ApprovedExecutable(path: "/replacement", identity: "replacement", version: "1.0.0")
        coordinator.executableApproved()
        await settle { await coordinator.poll(); return await backend.starts == 1 }
        _ = await coordinator.stop()
    }

    func testExplicitAccountRetryBypassesBackoffButOrdinaryRefreshPreservesIt() async {
        let model = model(), attempts = FixtureAttempts()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in await attempts.record(); throw NSError(domain: "Fixture", code: 1) },
            evidence: { .unavailable(.permissionDenied) })
        let beforeFailure = Date()
        await coordinator.poll(now: beforeFailure)
        await settle { model.connectionIssue == .disconnected }
        coordinator.refresh(); await coordinator.poll(now: beforeFailure)
        let ordinaryCalls = await attempts.count
        XCTAssertEqual(ordinaryCalls, 1)
        coordinator.retryAccount(); await coordinator.poll(now: beforeFailure)
        await settle { await attempts.count == 2 }
        _ = await coordinator.stop()
    }

    func testPinnedDuplicateIdentityInvalidatesContextAndRecoversWhenUnique() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(pinnedID: "fixture-root"), backend = FixtureBackend()
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Remote task", updatedAt: Date(), sessionPath: file.path)])
        let contexts = ContextSnapshotRepository(root: root)
        let coordinator = MonitorCoordinator(model: model, contexts: contexts,
            factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 }
        model.track(.pinned("fixture-root"))
        let duplicate = root.appendingPathComponent("duplicate.jsonl")
        try FileManager.default.copyItem(at: file, to: duplicate)
        await settle {
            coordinator.refresh(); await coordinator.poll()
            return model.selectedTask?.context.unavailableReason == .unsupportedSchema
        }
        XCTAssertEqual(model.selection.provenance, .pinned)
        XCTAssertNil(model.selectedTask?.task.sessionPath)
        try appendCounter(to: file)
        coordinator.refresh(); await coordinator.poll()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.selectedTask?.context.value, "Neither watcher reads nor remote metadata may restore conflicted context")
        XCTAssertNil(model.selectedTask?.task.sessionPath)
        try FileManager.default.removeItem(at: duplicate)
        await settle {
            coordinator.refresh(); await coordinator.poll()
            return model.selectedTask?.context.value?.latestResponse.total == 300
        }
        XCTAssertEqual(model.selection.provenance, .pinned)
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)
        _ = await coordinator.stop()
    }

    func testInaccessibleLocalDirectoryReportsPermissionAndRecovers() async throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses directory permission checks")
        let (root, _) = try localFixture()
        defer { _ = chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0), 0)
        let model = model(approved: false, pinnedID: "fixture-root")
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            evidence: { .unavailable(.permissionDenied) })
        await coordinator.poll()
        await settle { model.localDiscoveryIssue == .permissionDenied }
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        await settle {
            coordinator.refresh(); await coordinator.poll()
            return model.selectedTask?.context.value?.latestResponse.total == 250
        }
        XCTAssertNil(model.localDiscoveryIssue)
        _ = await coordinator.stop()
    }

    func testOldRootCompletionCannotClearNewRootLineageRequest() async {
        let model = model(pinnedID: "old"), backend = FixtureBackend(), oldGate = FixtureGate(), newGate = FixtureGate()
        let old = TaskSummary(id: "old", title: "Old root", updatedAt: Date())
        let new = TaskSummary(id: "new", title: "New root", updatedAt: Date())
        await backend.setRecent([old, new])
        await backend.setDescendantGate(oldGate, for: old.id)
        await backend.setDescendantGate(newGate, for: new.id)
        model.settings.includeSubagents = true
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot),
            factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        model.onTaskTrackingChange = { coordinator.taskTrackingChanged() }
        await settle { await coordinator.poll(); return await oldGate.entered }
        model.track(.pinned(new.id))
        await settle { await coordinator.poll(); return await newGate.entered }
        await oldGate.release()
        for _ in 0..<20 { await Task.yield() }
        coordinator.refresh()
        await coordinator.poll(now: Date().addingTimeInterval(60))
        for _ in 0..<20 { await Task.yield() }
        let reads = await backend.descendantReads[new.id]
        XCTAssertEqual(reads, 1, "The old cancelled request must not clear ownership of the pending new-root request")
        await newGate.release()
        _ = await coordinator.stop()
    }

    func testTransientRemoteCatalogFailurePreservesPinnedLocalWatcher() async throws {
        let (root, file) = try localFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(pinnedID: "fixture-root"), backend = FixtureBackend()
        await backend.setRecent([TaskSummary(id: "fixture-root", title: "Remote title", updatedAt: Date())])
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: root),
            factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
        coordinator.start()
        await settle { model.selectedTask?.context.value?.latestResponse.total == 250 && model.selectedTask?.task.title == "Remote title" }
        model.track(.pinned("fixture-root"))
        await backend.setCatalogFails(true)
        coordinator.refresh(); await coordinator.poll()
        await settle { model.selectedTask?.task.title != "Remote title" }
        try appendCounter(to: file)
        await settle { model.selectedTask?.context.value?.latestResponse.total == 300 }
        XCTAssertEqual(model.selection.provenance, .pinned)
        await backend.setCatalogFails(false)
        coordinator.refresh(); await coordinator.poll()
        await settle { model.selectedTask?.task.title == "Remote title" }
        try assertSameFile(model.selectedTask?.task.sessionPath, as: file)
        _ = await coordinator.stop()
    }

    func testBackoffCapsAndResets() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<8).map { _ in backoff.failed() }, [1, 2, 4, 8, 16, 30, 30, 30])
        backoff.reset(); XCTAssertEqual(backoff.failed(), 1)
    }

    func testCatalogRefreshesEveryFiveSecondsAndAccountEveryThirty() async {
        let backend = FixtureBackend(), model = model()
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: emptyRoot), factory: { _ in backend }, evidence: { .unavailable(.permissionDenied) })
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

    func testLocalDiscoveryAndPersistedCounterUpdatesWithoutCLIWithinTwoSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let file = root.appendingPathComponent("task.jsonl")
        try FileManager.default.copyItem(at: fixture, to: file)
        let backend = FixtureBackend(), model = model(approved: false, pinnedID: "fixture-root")
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
        let starts = await backend.starts
        XCTAssertEqual(starts, 0)
        let stopped = await coordinator.stop(); XCTAssertTrue(stopped)
    }
}
