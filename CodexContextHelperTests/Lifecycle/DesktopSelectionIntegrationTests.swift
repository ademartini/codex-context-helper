import XCTest
import SQLite3
@testable import CodexContextHelper

@MainActor
final class DesktopSelectionIntegrationTests: XCTestCase {
    func testRealLogReaderSelectsOffRecentLocalTaskAndKeepsTitlesAndCountersTogetherWithoutCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions"), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("2026/01/01"), withIntermediateDirectories: true)
        let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let text = try String(contentsOf: fixture, encoding: .utf8)
        try text.replacingOccurrences(of: "fixture-root", with: a).write(to: sessions.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try text.replacingOccurrences(of: "fixture-root", with: b).replacingOccurrences(of: "fixture-model", with: "second-model")
            .replacingOccurrences(of: "total_tokens\":250", with: "total_tokens\":300").replacingOccurrences(of: "output_tokens\":50", with: "output_tokens\":100")
            .write(to: sessions.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("titles.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT); INSERT INTO local_thread_catalog VALUES ('local','\(a)','First task'),('local','\(b)','Second task');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let log = logs.appendingPathComponent("2026/01/01/codex-desktop-11111111-1111-4111-8111-111111111111-1234-t0-i1-000000-0.log")
        func event(_ id: String, _ second: Int, active: Bool = true) -> String {
            "2026-01-01T00:00:0\(second).000Z info [electron-message-handler] thread_stream_view_activity_changed active=\(active) conversationId=\(id) rendererWebContentsId=1 rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowId=1 rendererWindowVisible=true\n"
        }
        try event(a, 1).write(to: log, atomically: true, encoding: .utf8)
        let reader = DesktopSelectionRepository(root: logs)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let model = PanelViewModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "fixture.selection.\(UUID().uuidString)")!))
        model.settings.recentTaskCount = 1
        let coordinator = MonitorCoordinator(model: model, contexts: ContextSnapshotRepository(root: sessions),
            desktopTitles: DesktopTaskTitleRepository(databaseURL: root.appendingPathComponent("titles.sqlite")),
            evidence: { await reader.selection(for: .init(processID: 1234, launchedAt: start), now: start.addingTimeInterval(60)) })
        model.onTaskTrackingChange = { coordinator.taskTrackingChanged() }
        func settle(_ id: String, title: String, total: Int64) async {
            for _ in 0..<150 {
                await coordinator.poll(now: Date().addingTimeInterval(10))
                if model.selectedTask?.id == id, model.selectedTask?.task.title == title,
                   model.selectedTask?.context.value?.latestResponse.total == total { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Selected title and context did not follow the exact local log identity")
        }
        await settle(a, title: "First task", total: 250)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data((event(a, 2, active: false) + event(b, 2)).utf8))
        coordinator.refresh()
        await settle(b, title: "Second task", total: 300)
        XCTAssertEqual(model.selection.provenance, .exact)
        XCTAssertEqual(model.connectionIssue, .unapprovedExecutable)
        model.track(.pinned(b))
        try handle.write(contentsOf: Data((event(b, 3, active: false) + event(a, 3)).utf8))
        await coordinator.poll(now: Date().addingTimeInterval(20))
        XCTAssertEqual(model.selectedTask?.id, b, "A manual pin must not move with desktop selection")
        model.track(.codex)
        await settle(a, title: "First task", total: 250)
        try handle.close()
        _ = await coordinator.stop()
    }
}
