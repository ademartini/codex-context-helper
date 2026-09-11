import XCTest
import SQLite3
@testable import CodexContextHelper

final class DesktopTaskTitleRepositoryTests: XCTestCase, @unchecked Sendable {
    private func withDatabase(_ body: (URL, OpaquePointer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        try await body(url, opened)
    }

    private func execute(_ sql: String, on database: OpaquePointer) {
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func createTable(_ database: OpaquePointer) {
        execute("CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT, preview TEXT)", on: database)
    }

    func testOnlyKnownLocalIdentitiesReceiveDesktopDisplayTitles() async throws {
        try await withDatabase { url, database in
            createTable(database)
            execute("INSERT INTO local_thread_catalog VALUES ('local', 'known', 'Desktop task', 'PRIVATE_PROMPT'), ('remote', 'known', 'Other host', 'PRIVATE_PROMPT'), ('local', 'unknown', 'Unrequested task', 'PRIVATE_PROMPT'), ('remote', 'remote-only', 'Remote task', 'PRIVATE_PROMPT')", on: database)
            let repository = DesktopTaskTitleRepository(databaseURL: url)
            let titles = await repository.titles(for: ["known", "remote-only", "missing"])
            XCTAssertEqual(titles, ["known": "Desktop task"])
            XCTAssertFalse(String(describing: titles).contains("PRIVATE_"))
        }
    }

    func testChangedTitlesAreReadWithoutStaleCache() async throws {
        try await withDatabase { url, database in
            createTable(database)
            execute("INSERT INTO local_thread_catalog VALUES ('local', 'known', 'Original name', 'PRIVATE_PROMPT')", on: database)
            let repository = DesktopTaskTitleRepository(databaseURL: url)
            let initial = await repository.titles(for: ["known"])
            XCTAssertEqual(initial["known"], "Original name")
            execute("UPDATE local_thread_catalog SET display_title = 'Renamed task'", on: database)
            let renamed = await repository.titles(for: ["known"])
            XCTAssertEqual(renamed["known"], "Renamed task")
        }
    }

    func testRequestedIdentityCountAndParametersAreBounded() async throws {
        try await withDatabase { url, database in
            createTable(database)
            execute("INSERT INTO local_thread_catalog VALUES ('local', 'last', 'Outside request limit', ''), ('local', 'known', 'Fixture task', '')", on: database)
            let repository = DesktopTaskTitleRepository(databaseURL: url)
            let bounded = await repository.titles(for: (0..<512).map { "missing-\($0)" } + ["last"])
            XCTAssertTrue(bounded.isEmpty)
            let parameters = await repository.titles(for: ["' OR 1=1 --", "known\0suffix", String(repeating: "x", count: 129), "known"])
            XCTAssertEqual(parameters, ["known": "Fixture task"])
        }
    }

    func testInvalidOrDuplicateTitlesNeverFallBackToPreview() async throws {
        try await withDatabase { url, database in
            createTable(database)
            execute("INSERT INTO local_thread_catalog VALUES ('local', 'null', NULL, 'PRIVATE_PROMPT'), ('local', 'blank', '   ', 'PRIVATE_PROMPT'), ('local', 'long', '\(String(repeating: "x", count: 513))', 'PRIVATE_PROMPT'), ('local', 'control', 'line' || char(10) || 'break', 'PRIVATE_PROMPT'), ('local', 'duplicate', 'One', 'PRIVATE_PROMPT'), ('local', 'duplicate', 'Two', 'PRIVATE_PROMPT'), ('local', 'blob', x'7469746c65', 'PRIVATE_PROMPT')", on: database)
            let titles = await DesktopTaskTitleRepository(databaseURL: url).titles(for: ["null", "blank", "long", "control", "duplicate", "blob"])
            XCTAssertTrue(titles.isEmpty)
        }
    }

    func testMissingDatabaseAndChangedSchemaAreOptional() async throws {
        try await withDatabase { url, database in
            let missingURL = url.deletingLastPathComponent().appendingPathComponent("missing.db")
            let missing = await DesktopTaskTitleRepository(databaseURL: missingURL).titles(for: ["known"])
            XCTAssertTrue(missing.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
            execute("CREATE TABLE local_thread_catalog (thread_id TEXT, legacy_title TEXT)", on: database)
            let changed = await DesktopTaskTitleRepository(databaseURL: url).titles(for: ["known"])
            XCTAssertTrue(changed.isEmpty)
        }
    }

    func testViewsAreNotUsedAsDesktopTitleTables() async throws {
        try await withDatabase { url, database in
            execute("CREATE VIEW local_thread_catalog AS SELECT 'local' AS host_id, 'known' AS thread_id, 'PRIVATE_PROMPT' AS display_title", on: database)
            let titles = await DesktopTaskTitleRepository(databaseURL: url).titles(for: ["known"])
            XCTAssertTrue(titles.isEmpty)
        }
    }

    func testDatabaseAndSidecarSymlinksAreRejected() async throws {
        try await withDatabase { url, database in
            createTable(database)
            execute("INSERT INTO local_thread_catalog VALUES ('local', 'known', 'Fixture task', '')", on: database)
            let link = url.deletingLastPathComponent().appendingPathComponent("linked.db")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let linked = await DesktopTaskTitleRepository(databaseURL: link).titles(for: ["known"])
            XCTAssertTrue(linked.isEmpty)
            let sidecar = URL(fileURLWithPath: url.path + "-wal")
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: url)
            let titles = await DesktopTaskTitleRepository(databaseURL: url).titles(for: ["known"])
            XCTAssertTrue(titles.isEmpty)
        }
    }





}
