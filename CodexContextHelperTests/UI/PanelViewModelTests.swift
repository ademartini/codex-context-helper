import XCTest
@testable import CodexContextHelper

@MainActor
final class PanelViewModelTests: XCTestCase {
    func testDefaultFollowsClickedTaskAndReturningFromPinClearsOldReading() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        XCTAssertEqual(model.trackingMode, .codex)
        model.tasks = [TaskSnapshot(task: TaskSummary(id: "pinned", title: "Pinned", updatedAt: Date()))]
        model.track(.pinned("pinned"))
        model.track(.codex)
        XCTAssertNil(model.selectedTask, "Wait for selection evidence instead of showing the old pin")
        XCTAssertEqual(model.trackingLabel, "Following Codex selection")
    }
    func testOpeningAgentsKeepsCompactNavigationAndTemporarilyEnablesDiscovery() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        let root = TaskSummary(id: "root", title: "Root task", updatedAt: Date())
        model.tasks = [TaskSnapshot(task: root)]
        model.selection = TaskSelection(threadID: root.id, provenance: .exact)
        model.openAgents()
        XCTAssertTrue(model.showsAgents)
        XCTAssertFalse(model.settings.includeSubagents)
        XCTAssertTrue(model.tracksAgents)
        XCTAssertFalse(model.settings.isExpanded)
        XCTAssertNil(model.detailID)
        model.selection = TaskSelection(threadID: "another", provenance: .exact)
        XCTAssertEqual(model.agentRootTask?.id, root.id, "Agent page stays attached to the task that was opened")
        model.back()
        XCTAssertFalse(model.showsAgents)
        XCTAssertFalse(model.settings.isExpanded)
    }
    func testDetailNavigationPreservesTopRightAnchorAndWidth() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        let controller = FloatingPanelController(model: model)
        let original = controller.panel.frame
        model.detailID = "fixture"
        controller.updateLayout()
        XCTAssertEqual(controller.panel.frame.width, original.width)
        XCTAssertEqual(controller.panel.frame.maxX, original.maxX)
        XCTAssertEqual(controller.panel.frame.maxY, original.maxY)
        model.detailID = nil
        controller.updateLayout()
        XCTAssertEqual(controller.panel.frame, original)
        controller.panel.orderOut(nil)
    }
    func testPinAndFollowCodexAreExplicitAndHistoryDoesNotChangeSelection() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.tasks = [TaskSnapshot(task: TaskSummary(id: "older", title: "Older", updatedAt: Date(timeIntervalSince1970: 10))),
                       TaskSnapshot(task: TaskSummary(id: "latest", title: "Latest", updatedAt: Date(timeIntervalSince1970: 20)))]
        model.track(.pinned("older"))
        XCTAssertEqual(model.selectedTask?.id, "older")
        XCTAssertEqual(model.selection.provenance, .pinned)
        model.openHistory(); XCTAssertTrue(model.showsHistory)
        model.back(); XCTAssertFalse(model.showsHistory)
        XCTAssertEqual(model.selectedTask?.id, "older")
        model.track(.codex)
        XCTAssertNil(model.selectedTask)
        model.track(.pinned("unknown"))
        XCTAssertEqual(model.trackingMode, .codex)
    }
    func testContextLabelUsesCodexBaselineAndMarksEstimate() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        let task = TaskSummary(id: "root", title: "Fixture", updatedAt: Date())
        let latest = TokenCounters(input: 56_000, cachedInput: 30_000, output: 0, reasoningOutput: 0, total: 56_000)!
        let cumulative = TokenCounters(input: 800_000, cachedInput: 400_000, output: 0, reasoningOutput: 0, total: 800_000)!
        let snapshot = ContextSnapshot(latestResponse: latest, cumulative: cumulative, modelContextWindow: 100_000)!
        let row = TaskSnapshot(task: task, context: .available(snapshot, DataProvenance(source: .sessionLog, schemaVersion: SessionLogSchema.version)))
        XCTAssertEqual(model.contextLabel(row), "50% remaining")
        XCTAssertFalse(model.occupancyVerified, "Source-backed estimates must not claim live verification")
    }
    func testSelectionAndUnavailableContextNeverProduceZero() {
        let defaults = UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: defaults))
        let task = TaskSummary(id: "root", title: "Fixture task", updatedAt: Date(), model: "fixture-model")
        model.tasks = [TaskSnapshot(task: task)]
        model.selection = TaskSelection(threadID: "root", provenance: .exact)
        XCTAssertEqual(model.selectedTask?.task.title, "Fixture task")
        XCTAssertEqual(model.contextLabel(model.tasks[0]), "Unavailable")
        XCTAssertEqual(model.creditsLabel(model.tasks[0].cost), "Unavailable")
        model.openDetail("root"); XCTAssertEqual(model.detailID, "root")
        model.back(); XCTAssertNil(model.detailID)
    }
    func testSettingsBoundsAndPanelFrameClamping() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.setRecentTaskCount(50); XCTAssertEqual(model.settings.recentTaskCount, 10)
        model.setRecentTaskCount(0); XCTAssertEqual(model.settings.recentTaskCount, 1)
        let frame = FloatingPanelController.clampedFrame(NSRect(x: 9000, y: -9000, width: 360, height: 240), screens: [NSRect(x: 0, y: 0, width: 1280, height: 800)])
        XCTAssertTrue(NSRect(x: 0, y: 0, width: 1280, height: 800).contains(frame))
    }
    func testMainViewOnlyShowsFreshnessNoticeWhenDataIsStale() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.now = Date(timeIntervalSince1970: 1000)
        let fresh: Metric<Int> = .available(1, DataProvenance(source: .sessionLog, schemaVersion: "fixture", observedAt: model.now))
        XCTAssertNil(model.staleNotice(fresh))
        XCTAssertNotNil(model.staleNotice(fresh.markedStale()))
        model.now.addTimeInterval(61)
        XCTAssertNotNil(model.staleNotice(fresh))
        XCTAssertNil(model.staleNotice(Metric<Int>.unavailable(.noData)))
    }
    func testLocalDiscoveryStartsWithoutRequiringAnAccountConnection() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        XCTAssertEqual(model.localDiscoveryIssue, .connecting)
        XCTAssertEqual(model.connectionIssue, .unapprovedExecutable)
        XCTAssertEqual(model.localEmptyTitle, "Looking for local Codex activity…")
        model.localDiscoveryIssue = .noData
        XCTAssertEqual(model.localEmptyTitle, "No local Codex activity yet")
        model.localDiscoveryIssue = .permissionDenied
        XCTAssertEqual(model.localEmptyTitle, "Can’t read local Codex activity")
        XCTAssertTrue(model.localEmptyExplanation.contains("session folder"))
        XCTAssertFalse(model.localEmptyExplanation.contains("Accessibility"))
        model.localDiscoveryIssue = .unsupportedSchema
        XCTAssertEqual(model.localEmptyTitle, "Local activity format unavailable")
    }
    func testDisconnectClearsSavedApprovalAndStalesOnlyAccountReadings() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!)
        let model = PanelViewModel(settingsStore: store)
        model.settings.approvedExecutable = ApprovedExecutable(path: "/fixture/codex", identity: "fixture", version: "1.0.0")
        model.persist()
        let source = DataProvenance(source: .appServer, schemaVersion: "fixture")
        model.account = AccountUsageSnapshot(quotas: .available([], source), dailyTokens: .available([DailyTokenUsage(day: "2026-09-11", tokens: 10)], source))
        let local = TaskSnapshot(task: TaskSummary(id: "local", title: "Local task", updatedAt: Date()))
        model.tasks = [local]
        model.track(.pinned(local.id))
        model.localDiscoveryIssue = nil
        var disconnects = 0
        model.onDisconnectAccount = { disconnects += 1 }
        model.disconnectAccountUsage()
        XCTAssertNil(model.settings.approvedExecutable)
        XCTAssertNil(store.load().approvedExecutable)
        XCTAssertEqual(model.connectionIssue, .unapprovedExecutable)
        XCTAssertEqual(disconnects, 1)
        XCTAssertTrue(model.account.quotas.provenance!.invalidated)
        XCTAssertTrue(model.account.dailyTokens.provenance!.invalidated)
        XCTAssertEqual(model.account.dailyTokens.value?.first?.tokens, 10)
        XCTAssertNil(model.localDiscoveryIssue)
        XCTAssertEqual(model.selectedTask, local)
        XCTAssertEqual(model.trackingMode, .pinned(local.id))
    }
    func testAccountUpdateAndRetryLeaveLocalSelectionAvailable() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.tasks = [TaskSnapshot(task: TaskSummary(id: "local", title: "Local task", updatedAt: Date()))]
        model.track(.pinned("local"))
        model.localDiscoveryIssue = nil
        model.connectionIssue = .executableChanged
        XCTAssertEqual(model.accountConnectionLabel, "Codex CLI updated · review to reconnect")
        var refreshes = 0, retries = 0
        model.onRefresh = { refreshes += 1 }
        model.onRetryAccount = { retries += 1 }
        model.retryAccountUsage()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(refreshes, 0)
        model.refresh()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.selectedTask?.id, "local")
        XCTAssertNil(model.localDiscoveryIssue)
        model.connectionIssue = .signedOut
        XCTAssertEqual(model.accountConnectionLabel, "Sign in to the Codex CLI, then retry")
    }
    func testApprovalFailureCopyDescribesTheActualFailure() {
        XCTAssertTrue(PanelViewModel.approvalFailureMessage(ExecutableError.unsafePermissions).contains("ownership or permissions"))
        XCTAssertTrue(PanelViewModel.approvalFailureMessage(ExecutableError.unsupportedVersion).contains("recognized Codex CLI version"))
        XCTAssertTrue(PanelViewModel.approvalFailureMessage(ExecutableError.timedOut).contains("respond in time"))
        XCTAssertFalse(PanelViewModel.approvalFailureMessage(ExecutableError.unsupportedVersion).contains("0.153.4"))
    }

}
