import XCTest
import Darwin
@testable import CodexContextHelper

final class LocalTaskCatalogTests: XCTestCase, @unchecked Sendable {
    private func withRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @discardableResult
    private func write(_ id: String, root: URL, filename: String? = nil, extra: String = "", version: String = "0.153.4") throws -> URL {
        let file = root.appendingPathComponent(filename ?? "\(id).jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cli_version\":\"\(version)\"\(extra)}}\n{\"type\":\"response_item\",\"payload\":{\"content\":\"PRIVATE_PROMPT\"}}\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testDataHomeUsesOnlyAbsoluteEnvironmentOverride() {
        let fallback = URL(fileURLWithPath: "/synthetic/home")
        XCTAssertEqual(CodexDataLocation.home(environment: ["CODEX_HOME": "/synthetic/custom"], userHome: fallback).path, "/synthetic/custom")
        for invalid in ["", "relative/path", "~/.codex", "\0"] {
            XCTAssertEqual(CodexDataLocation.home(environment: ["CODEX_HOME": invalid], userHome: fallback).path, "/synthetic/home/.codex")
        }
    }

    func testCompatibleReleasesHaveDistinctNeutralTitlesAndExplicitAgentsOnly() async throws {
        try await withRoot { root in
            try write("root-one", root: root, version: "0.154.0")
            try write("agent-two", root: root, extra: ",\"parent_thread_id\":\"root-one\",\"agent_nickname\":\"Helper\"", version: "0.200.0-alpha.1")
            try write("fork-three", root: root, extra: ",\"forked_from_id\":\"root-one\"")
            let catalog = LocalTaskCatalog(root: root)
            let result = await catalog.refresh()
            XCTAssertNil(result.issue)
            XCTAssertEqual(result.tasks.count, 3)
            XCTAssertEqual(Set(result.tasks.map(\.title)).count, 3)
            XCTAssertTrue(result.tasks.allSatisfy { $0.title.hasPrefix("Session ") && $0.sessionPath != nil })
            XCTAssertEqual(result.tasks.first { $0.id == "agent-two" }?.parentThreadID, "root-one")
            XCTAssertNil(result.tasks.first { $0.id == "fork-three" }?.parentThreadID)
            XCTAssertFalse(String(describing: result).contains("PRIVATE_PROMPT"))
        }
    }

    func testMissingEmptyMalformedAndOversizedStoresAreDistinct() async throws {
        try await withRoot { root in
            let missing = await LocalTaskCatalog(root: root.appendingPathComponent("missing")).refresh()
            XCTAssertEqual(missing.issue, .noData)
            let empty = await LocalTaskCatalog(root: root).refresh()
            XCTAssertEqual(empty.issue, .noData)
            try "{}\n".write(to: root.appendingPathComponent("bad.jsonl"), atomically: true, encoding: .utf8)
            let malformed = await LocalTaskCatalog(root: root).refresh()
            XCTAssertEqual(malformed.issue, .unsupportedSchema)
            try write("oversized", root: root)
            let bounded = await LocalTaskCatalog(root: root, maximumHeaderBytes: 16).refresh()
            XCTAssertEqual(bounded.issue, .unsupportedSchema)
            XCTAssertTrue(bounded.tasks.isEmpty)
        }
    }

    func testNearbySessionLabelsKeepDistinctIdentifierBeforeDate() async throws {
        try await withRoot { root in
            let ids = ["019934e2-0000-7000-8000-0000a1b2c3d4", "019934e2-0000-7000-8000-0000e5f6a7b8"]
            let created = Date(timeIntervalSince1970: 1_789_133_460)
            for id in ids {
                let file = try write(id, root: root)
                try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
            }
            let result = await LocalTaskCatalog(root: root).refresh()
            XCTAssertEqual(result.tasks.count, 2)
            XCTAssertEqual(Set(result.tasks.map(\.title)).count, 2)
            for task in result.tasks {
                XCTAssertTrue(task.title.hasPrefix("Session \(task.id.suffix(8)) · "))
                XCTAssertFalse(task.title.contains("PRIVATE_PROMPT"))
            }
        }
    }

    func testDeniedSessionDirectoryClearsCachedTasksAndRecoversAfterAccessRestored() async throws {
        try await withRoot { root in
            try write("readable-again", root: root)
            let catalog = LocalTaskCatalog(root: root)
            let initial = await catalog.refresh()
            XCTAssertEqual(initial.tasks.map(\.id), ["readable-again"])

            XCTAssertEqual(chmod(root.path, 0o000), 0)
            defer { _ = chmod(root.path, 0o700) }
            let denied = await catalog.refresh()
            XCTAssertEqual(denied.issue, .permissionDenied)
            XCTAssertTrue(denied.tasks.isEmpty)

            XCTAssertEqual(chmod(root.path, 0o700), 0)
            let recovered = await catalog.refresh()
            XCTAssertNil(recovered.issue)
            XCTAssertEqual(recovered.tasks.map(\.id), ["readable-again"])
        }
    }

    func testIncrementalEnumerationDoesNotStarveLaterFilesAndCacheIsBounded() async throws {
        try await withRoot { root in
            for index in 0..<12 {
                let file = try write("task-\(index)", root: root)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: file.path)
            }
            let catalog = LocalTaskCatalog(root: root, maximumTasks: 3, entriesPerRefresh: 1)
            var observed = Set<String>()
            for _ in 0..<30 {
                let result = await catalog.refresh()
                XCTAssertLessThanOrEqual(result.tasks.count, 3)
                observed.formUnion(result.tasks.map(\.id))
            }
            let latest = await catalog.refresh()
            XCTAssertEqual(Set(latest.tasks.map(\.id)), ["task-9", "task-10", "task-11"])
            XCTAssertTrue(observed.contains("task-11"))
        }
    }

    func testNewFilesRotationAndDeletionRefreshIdentity() async throws {
        try await withRoot { root in
            let file = try write("original", root: root, filename: "session.jsonl")
            let catalog = LocalTaskCatalog(root: root)
            let initial = await catalog.refresh()
            XCTAssertEqual(initial.tasks.map(\.id), ["original"])
            try write("replacement", root: root, filename: "session.jsonl", version: "0.155.1")
            try write("new-session", root: root)
            let rotated = await catalog.refresh()
            XCTAssertEqual(Set(rotated.tasks.map(\.id)), ["replacement", "new-session"])
            try FileManager.default.removeItem(at: file)
            let deleted = await catalog.refresh()
            XCTAssertEqual(deleted.tasks.map(\.id), ["new-session"])
        }
    }

    func testDuplicateIdentityDoesNotChooseAnArbitraryFileEvenAtCacheBoundary() async throws {
        try await withRoot { root in
            try write("duplicate", root: root, filename: "one.jsonl")
            try write("duplicate", root: root, filename: "two.jsonl")
            let catalog = LocalTaskCatalog(root: root, maximumTasks: 1)
            for _ in 0..<3 {
                let result = await catalog.refresh()
                XCTAssertTrue(result.tasks.isEmpty)
                XCTAssertEqual(result.issue, .unsupportedSchema)
                XCTAssertEqual(result.conflictedIDs, ["duplicate"])
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("two.jsonl"))
            _ = await catalog.refresh()
            let recovered = await catalog.refresh()
            XCTAssertEqual(recovered.tasks.map(\.id), ["duplicate"])
            XCTAssertTrue(recovered.conflictedIDs.isEmpty)
        }
    }

    func testRetainedDuplicateIdentitiesRemainConflictedAcrossScanGenerations() async throws {
        try await withRoot { root in
            try write("duplicate", root: root, filename: "one.jsonl")
            try write("duplicate", root: root, filename: "two.jsonl")
            try write("unambiguous", root: root)
            let catalog = LocalTaskCatalog(root: root)
            for _ in 0..<3 {
                let result = await catalog.refresh()
                XCTAssertEqual(result.tasks.map(\.id), ["unambiguous"])
                XCTAssertEqual(result.conflictedIDs, ["duplicate"])
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("two.jsonl"))
            _ = await catalog.refresh()
            let recovered = await catalog.refresh()
            XCTAssertEqual(Set(recovered.tasks.map(\.id)), ["duplicate", "unambiguous"])
            XCTAssertTrue(recovered.conflictedIDs.isEmpty)
        }
    }

    func testSymlinksNonRegularFilesInvalidIdentitiesAndExcessiveDepthAreIgnored() async throws {
        try await withRoot { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let target = try write("outside", root: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jsonl"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-dir"), withDestinationURL: outside)
            XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.jsonl").path, 0o600), 0)
            let deep = root.appendingPathComponent("1/2/3/4/5/6/7/8/9")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try write("too-deep", root: deep)
            try write("../bad-identity", root: root, filename: "bad.jsonl")
            try write("self-parent", root: root, extra: ",\"parent_thread_id\":\"self-parent\"")
            let result = await LocalTaskCatalog(root: root).refresh()
            XCTAssertTrue(result.tasks.isEmpty)
            XCTAssertEqual(result.issue, .unsupportedSchema)
        }
    }

    func testIncompleteInitialTraversalAndStopCanRestart() async throws {
        try await withRoot { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("2026"), withIntermediateDirectories: true)
            try write("later", root: root.appendingPathComponent("2026"))
            let catalog = LocalTaskCatalog(root: root, entriesPerRefresh: 1)
            let initial = await catalog.refresh()
            XCTAssertEqual(initial.issue, .connecting)
            let next = await catalog.refresh()
            XCTAssertEqual(next.tasks.map(\.id), ["later"])
            await catalog.stop()
            _ = await catalog.refresh()
            let restarted = await catalog.refresh()
            XCTAssertEqual(restarted.tasks.map(\.id), ["later"])
        }
    }
}
