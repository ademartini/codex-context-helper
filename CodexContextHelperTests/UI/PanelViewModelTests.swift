import XCTest
@testable import CodexContextHelper

@MainActor
final class PanelViewModelTests: XCTestCase {
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
    func testPinAndFollowLatestAreExplicitAndHistoryDoesNotChangeSelection() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.tasks = [TaskSnapshot(task: TaskSummary(id: "older", title: "Older", updatedAt: Date(timeIntervalSince1970: 10))),
                       TaskSnapshot(task: TaskSummary(id: "latest", title: "Latest", updatedAt: Date(timeIntervalSince1970: 20)))]
        model.track(.pinned("older"))
        XCTAssertEqual(model.selectedTask?.id, "older")
        XCTAssertEqual(model.selection.provenance, .pinned)
        model.openHistory(); XCTAssertTrue(model.showsHistory)
        model.back(); XCTAssertFalse(model.showsHistory)
        XCTAssertEqual(model.selectedTask?.id, "older")
        model.track(.latest)
        XCTAssertEqual(model.selectedTask?.id, "latest")
        model.track(.pinned("unknown"))
        XCTAssertEqual(model.trackingMode, .latest)
    }
    func testLatestActivityUsesRecencyRatherThanOnlyUpdatedTime() {
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.\(UUID().uuidString)")!))
        model.tasks = [TaskSnapshot(task: TaskSummary(id: "active", title: "Active", updatedAt: Date(timeIntervalSince1970: 10), recencyAt: Date(timeIntervalSince1970: 30))),
                       TaskSnapshot(task: TaskSummary(id: "updated", title: "Updated", updatedAt: Date(timeIntervalSince1970: 20)))]
        model.selectLatest()
        XCTAssertEqual(model.selectedTask?.id, "active")
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
}
