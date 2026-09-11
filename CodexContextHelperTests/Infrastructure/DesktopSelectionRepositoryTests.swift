import XCTest
@testable import CodexContextHelper

final class DesktopSelectionRepositoryTests: XCTestCase {
    private let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let session = "11111111-1111-4111-8111-111111111111"
    private let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
    private var process: DesktopAppInstance { DesktopAppInstance(processID: 1234, launchedAt: start) }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/01/01"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ root: URL, slot: Int = 0, sessionID: String? = nil, pid: Int = 1234) -> URL {
        root.appendingPathComponent("2026/01/01/codex-desktop-\(sessionID ?? session)-\(pid)-t0-i1-000000-\(slot).log")
    }
    private func event(_ id: String, second: Int, active: Bool = true, focused: Bool = true,
                       visible: Bool = true, window: Int = 1, appearance: String = "primary") -> String {
        "2026-01-01T00:00:\(String(format: "%02d", second)).000Z info [electron-message-handler] thread_stream_view_activity_changed active=\(active) conversationId=\(id) rendererWebContentsId=\(window) rendererWindowAppearance=\(appearance) rendererWindowFocused=\(focused) rendererWindowId=\(window) rendererWindowVisible=\(visible) resumeState=resumed streamRole=owner\n"
    }
    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    private func read(_ repo: DesktopSelectionRepository, instance: DesktopAppInstance? = nil) async -> TaskSelectionEvidence {
        await repo.selection(for: instance ?? process, now: start.addingTimeInterval(120))
    }

    func testBootstrapAndCachedTaskSwitchesWithoutMessages() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1), to: log)
        let repo = DesktopSelectionRepository(root: root)
        let first = await read(repo); XCTAssertEqual(first, .localTask(a))
        try append(event(a, second: 2, active: false) + event(b, second: 2), to: log)
        let second = await read(repo); XCTAssertEqual(second, .localTask(b))
        try append(event(b, second: 3, active: false) + event(a, second: 3), to: log)
        let third = await read(repo); XCTAssertEqual(third, .localTask(a))
        try append("2026-01-01T00:00:04.000Z info background_task_changed conversationId=\(b) active=true\n", to: log)
        let idle = await repo.selection(for: process, now: start.addingTimeInterval(36_000))
        XCTAssertEqual(idle, .localTask(a))
    }
    func testDeactivationClearsEvenWhenWindowIsHiddenAndUnfocused() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1) + event(a, second: 2, active: false, focused: false, visible: false), to: log)
        let result = await read(DesktopSelectionRepository(root: root))
        XCTAssertEqual(result, .unavailable(.noData))
    }
    func testBackgroundAndSecondaryViewsCannotChooseOrClearTask() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1) + event(b, second: 2, focused: false, window: 2)
                  + event(b, second: 3, window: 3, appearance: "secondary")
                  + event(a, second: 4, active: false, window: 2), to: log)
        let result = await read(DesktopSelectionRepository(root: root)); XCTAssertEqual(result, .localTask(a))
    }
    func testCurrentProcessOnlyAndQuitClearsSelection() async throws {
        let root = try fixture()
        try write(event(a, second: 1), to: file(root))
        try write(event(b, second: 10), to: file(root, pid: 4321))
        let repo = DesktopSelectionRepository(root: root)
        let selected = await read(repo); XCTAssertEqual(selected, .localTask(a))
        let quit = await repo.selection(for: nil); XCTAssertEqual(quit, .unavailable(.disconnected))
        let restarted = await read(repo, instance: DesktopAppInstance(processID: 1234, launchedAt: start.addingTimeInterval(30)))
        XCTAssertEqual(restarted, .unavailable(.noData))
    }
    func testConflictingProcessSessionsAreUnavailable() async throws {
        let root = try fixture()
        try write(event(a, second: 1), to: file(root))
        try write(event(b, second: 2), to: file(root, sessionID: "22222222-2222-4222-8222-222222222222"))
        let result = await read(DesktopSelectionRepository(root: root))
        XCTAssertEqual(result, .unavailable(.ambiguousSelection))
    }
    func testPartialLineIsNotAcceptedAndLaterCompletes() async throws {
        let root = try fixture(), log = file(root), line = event(a, second: 1)
        try write(String(line.dropLast()), to: log)
        let repo = DesktopSelectionRepository(root: root)
        let partial = await read(repo); XCTAssertEqual(partial, .unavailable(.connecting))
        try append("\n", to: log)
        let complete = await read(repo); XCTAssertEqual(complete, .localTask(a))
    }
    func testBudgetNeverPublishesPositiveBeforeUnreadDeactivation() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1) + String(repeating: "unrelated\n", count: 100) + event(a, second: 2, active: false), to: log)
        let repo = DesktopSelectionRepository(root: root, byteBudget: 128)
        var result = await read(repo)
        XCTAssertEqual(result, .unavailable(.connecting))
        for _ in 0..<30 where result == .unavailable(.connecting) { result = await read(repo) }
        XCTAssertEqual(result, .unavailable(.noData))
    }
    func testRotationOrdersByRecordTimeNotFilenameSlot() async throws {
        let root = try fixture()
        try write(event(a, second: 1), to: file(root, slot: 4))
        try write(event(a, second: 2, active: false) + event(b, second: 2), to: file(root, slot: 0))
        let result = await read(DesktopSelectionRepository(root: root)); XCTAssertEqual(result, .localTask(b))
    }
    func testConflictingEqualTimestampsAcrossFilesAreUnavailable() async throws {
        let root = try fixture()
        try write(event(a, second: 1), to: file(root, slot: 0))
        try write(event(b, second: 1), to: file(root, slot: 1))
        let result = await read(DesktopSelectionRepository(root: root)); XCTAssertEqual(result, .unavailable(.ambiguousSelection))
    }
    func testDroppedRecordsAndMalformedSelectionInvalidateUntilNextValidEvent() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1) + "[file-logger] dropped 5 lines due to backpressure\n", to: log)
        let repo = DesktopSelectionRepository(root: root)
        let dropped = await read(repo); XCTAssertEqual(dropped, .unavailable(.unsupportedSchema))
        try append(event(b, second: 2), to: log)
        let restored = await read(repo); XCTAssertEqual(restored, .localTask(b))
        try append(event(a, second: 3).replacingOccurrences(of: " rendererWindowVisible=true", with: ""), to: log)
        let malformed = await read(repo); XCTAssertEqual(malformed, .unavailable(.unsupportedSchema))
    }
    func testSymlinkIsRejected() async throws {
        let root = try fixture(), log = file(root), other = root.appendingPathComponent("other")
        try write(event(a, second: 1), to: other)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: other)
        let result = await read(DesktopSelectionRepository(root: root))
        XCTAssertEqual(result, .unavailable(.unsupportedSchema))
    }
    func testNewRotatedFileWithUntimestampedGapCannotReviveOlderPositive() async throws {
        let root = try fixture(), next = file(root, slot: 1)
        try write(event(a, second: 1), to: file(root))
        try write("[file-logger] dropped 8 lines due to backpressure\n", to: next)
        let repo = DesktopSelectionRepository(root: root)
        let gap = await read(repo); XCTAssertEqual(gap, .unavailable(.unsupportedSchema))
        try append(event(b, second: 2), to: next)
        let recovered = await read(repo); XCTAssertEqual(recovered, .localTask(b))
    }
    func testEqualTimestampAmbiguityPersistsThroughWholeBucket() async throws {
        let root = try fixture(), other = file(root, slot: 1)
        try write(event(a, second: 1), to: file(root))
        try write(event(b, second: 1) + event(b, second: 1), to: other)
        let repo = DesktopSelectionRepository(root: root)
        let tied = await read(repo); XCTAssertEqual(tied, .unavailable(.ambiguousSelection))
        try append(event(b, second: 2), to: other)
        let later = await read(repo); XCTAssertEqual(later, .localTask(b))
    }
    func testMalformedTimestampOnNamedEventInvalidatesSelection() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1) + event(b, second: 2).replacingOccurrences(of: "2026-01-01T00:00:02.000Z", with: "invalid-time"), to: log)
        let result = await read(DesktopSelectionRepository(root: root))
        XCTAssertEqual(result, .unavailable(.unsupportedSchema))
    }
    func testInPlaceRewriteInvalidatesOldSelectionAndFreshAppendRecovers() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1), to: log)
        let repo = DesktopSelectionRepository(root: root)
        let first = await read(repo); XCTAssertEqual(first, .localTask(a))
        // Reuse the inode and length, as the logger can when rotating into a slot.
        try write(event(b, second: 2), to: log)
        let replaced = await read(repo); XCTAssertEqual(replaced, .unavailable(.unsupportedSchema))
        let later = event(b, second: 3).replacingOccurrences(of: "00:00:03", with: "00:02:01")
        try append(later, to: log)
        let recovered = await repo.selection(for: process, now: start.addingTimeInterval(122))
        XCTAssertEqual(recovered, .localTask(b))
    }
    func testUTCMidnightKeepsSameProcessSelection() async throws {
        let root = try fixture(), tomorrow = root.appendingPathComponent("2026/01/02")
        try write(event(a, second: 1), to: file(root))
        let repo = DesktopSelectionRepository(root: root)
        let first = await read(repo); XCTAssertEqual(first, .localTask(a))
        try FileManager.default.createDirectory(at: tomorrow, withIntermediateDirectories: true)
        let next = tomorrow.appendingPathComponent(file(root).lastPathComponent)
        try write(event(b, second: 1).replacingOccurrences(of: "2026-01-01", with: "2026-01-02"), to: next)
        let midnight = await repo.selection(for: process, now: start.addingTimeInterval(86_405))
        XCTAssertEqual(midnight, .localTask(b))
    }

    func testDisappearingCaughtUpFileCannotRestoreStaleSelection() async throws {
        let root = try fixture(), log = file(root)
        try write(event(a, second: 1), to: log)
        let repo = DesktopSelectionRepository(root: root)
        let first = await read(repo); XCTAssertEqual(first, .localTask(a))
        try FileManager.default.removeItem(at: log)
        let removed = await read(repo); XCTAssertEqual(removed, .unavailable(.unsupportedSchema))
        let later = event(b, second: 3).replacingOccurrences(of: "00:00:03", with: "00:02:01")
        try write(later, to: file(root, slot: 1))
        let recovered = await repo.selection(for: process, now: start.addingTimeInterval(122))
        XCTAssertEqual(recovered, .localTask(b))
    }

}
