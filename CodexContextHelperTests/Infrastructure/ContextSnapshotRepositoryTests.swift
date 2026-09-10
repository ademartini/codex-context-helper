import XCTest
@testable import CodexContextHelper

final class ContextSnapshotRepositoryTests: XCTestCase, @unchecked Sendable {
    func testRepositoryBoundsWatchSetAndIsolatesMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let file = root.appendingPathComponent("task.jsonl")
        try FileManager.default.copyItem(at: fixture, to: file)
        let repo = ContextSnapshotRepository(root: root)
        let tasks = (0..<15).map { TaskSummary(id: $0 == 0 ? "fixture-root" : "missing-\($0)", title: "Fixture", updatedAt: Date(), sessionPath: file.path + ($0 == 0 ? "" : "missing")) }
        await repo.configure(tasks: tasks, onChange: { _ in })
        let results = await repo.refresh()
        let count = await repo.watchedTaskCount
        XCTAssertEqual(count, 10)
        XCTAssertEqual(results["fixture-root"]?.context.value?.latestResponse.total, 250)
        XCTAssertEqual(results["missing-1"]?.context.unavailableReason, .missingSession)
        await repo.stop()
    }
    func testFileEventReachesObserverPromptly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("task.jsonl")
        try Data().write(to: file)
        let watcher = SessionDirectoryWatcher(root: root)
        let changed = expectation(description: "Appended bytes trigger a bounded debounced refresh")
        changed.assertForOverFulfill = false
        watcher.update(paths: ["fixture-root": file.path]) { ids in
            if ids.contains("fixture-root") { changed.fulfill() }
        }
        await watcher.synchronize()
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
        await fulfillment(of: [changed], timeout: 2)
        watcher.stop(); await watcher.synchronize()
    }
}
