import Foundation
import Darwin
import SQLite3

/// Optional desktop display metadata. This private schema may disappear independently of
/// session logs; failure simply leaves the caller's neutral session labels in place.
actor DesktopTaskTitleRepository {
    private let databaseURL: URL
    private static let maximumTitleBytes = 512

    init(databaseURL: URL = CodexDataLocation.home.appendingPathComponent("sqlite/codex-dev.db")) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    /// Only enrich identities already verified by the session catalog. Never read prompt,
    /// preview, legacy title, account or remote-host data from the desktop store.
    func titles(for ids: [String]) -> [String: String] {
        let ids = Array(Set(ids.prefix(512).filter {
            !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0")
        })).sorted()
        guard !ids.isEmpty, !Task.isCancelled else { return [:] }
        return withDatabase { database, budget -> [String: String]? in
            var statement: OpaquePointer?
            let sql = "SELECT display_title FROM local_thread_catalog WHERE host_id = 'local' AND thread_id = ? LIMIT 2"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
            defer { sqlite3_finalize(statement) }
            var titles: [String: String] = [:]
            for id in ids {
                guard !Task.isCancelled, !budget.expired else { break }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let result = id.withCString { pointer -> Int32 in
                    let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    guard sqlite3_bind_text(statement, 1, pointer, -1, copy) == SQLITE_OK else { return SQLITE_ERROR }
                    return sqlite3_step(statement)
                }
                if result == SQLITE_DONE { continue }
                guard result == SQLITE_ROW else { return [:] }
                guard let title = Self.text(statement, column: 0, maximumBytes: Self.maximumTitleBytes),
                      Self.isValidTitle(title) else { continue }
                // An unexpected duplicate local identity is ambiguous, never pick a title.
                let next = sqlite3_step(statement)
                if next == SQLITE_DONE { titles[id] = title }
                else if next != SQLITE_ROW { return [:] }
            }
            return titles
        } ?? [:]
    }

    private static func text(_ statement: OpaquePointer, column: Int32, maximumBytes: Int) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= maximumBytes, let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }

    private static func isValidTitle(_ title: String) -> Bool {
        !title.isEmpty && title.utf8.count <= maximumTitleBytes &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func withDatabase<Result>(_ read: (OpaquePointer, ReadBudget) -> Result?) -> Result? {
        // Foundation may abbreviate /private/var back to /var even after resolving
        // symlinks. SQLite's NOFOLLOW rejects that alias, so retain the POSIX path.
        // Resolve only the configured directory; the database leaf must remain link-free.
        guard let parent = realpath(databaseURL.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + databaseURL.lastPathComponent
        var original = stat()
        guard lstat(path, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size > 0, original.st_size <= 256 * 1024 * 1024 else { return nil }
        // SQLite may consult WAL sidecars. Reject links before opening any of them.
        for suffix in ["-wal", "-shm"] {
            var info = stat()
            if lstat(path + suffix, &info) == 0, info.st_mode & S_IFMT != S_IFREG { return nil }
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        var opened = stat()
        guard lstat(path, &opened) == 0, opened.st_dev == original.st_dev,
              opened.st_ino == original.st_ino, opened.st_mode & S_IFMT == S_IFREG else { return nil }
        sqlite3_busy_timeout(database, 0)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 4096)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 4096)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 64)
        guard sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else { return nil }
        let budget = ReadBudget()
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<ReadBudget>.fromOpaque(pointer).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard isOrdinaryTable(database) else { return nil }
        let result = read(database, budget)
        var current = stat()
        guard lstat(path, &current) == 0, current.st_ino == original.st_ino,
              current.st_dev == original.st_dev, current.st_mode & S_IFMT == S_IFREG else { return nil }
        return result
    }

    private func isOrdinaryTable(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        // A real table is required; do not run a changed schema's view or virtual table.
        let sql = "SELECT 1 FROM pragma_table_list WHERE schema = 'main' AND name = 'local_thread_catalog' AND type = 'table'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_step(statement) == SQLITE_DONE
    }

    private final class ReadBudget {
        private let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        var expired: Bool { ContinuousClock.now >= deadline }
    }
}
