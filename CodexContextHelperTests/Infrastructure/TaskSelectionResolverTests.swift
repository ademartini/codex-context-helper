import XCTest
@testable import CodexContextHelper

final class TaskSelectionResolverTests: XCTestCase {
    private let tasks = [TaskSummary(id: "older", title: "Shared", updatedAt: Date(timeIntervalSince1970: 1)),
                         TaskSummary(id: "newer", title: "Unique", updatedAt: Date(timeIntervalSince1970: 2))]
    func testUniqueSelectionIsExactAndPermissionDenialNeverSelectsAnotherTask() {
        let exact = TaskSelectionResolver.resolve(tasks: tasks, evidence: .selected(ids: ["newer"], titles: ["Unique"]))
        XCTAssertEqual(exact.threadID, "newer"); XCTAssertEqual(exact.provenance, .exact)
        let fallback = TaskSelectionResolver.resolve(tasks: tasks, evidence: .unavailable(.permissionDenied))
        XCTAssertNil(fallback.threadID)
        XCTAssertEqual(fallback.provenance, .inferred(.permissionDenied))
    }
    func testUniqueTitleAloneCannotIdentifyTaskAcrossMixedDesktopSurfaces() {
        XCTAssertNil(TaskSelectionResolver.resolve(tasks: tasks, evidence: .selected(ids: [], titles: ["Unique"])).threadID)
    }
    func testDuplicateTitlesAndConflictingEvidenceRefuseExactSelection() {
        var duplicate = tasks; duplicate[1].title = "Shared"
        XCTAssertNotEqual(TaskSelectionResolver.resolve(tasks: duplicate, evidence: .selected(ids: [], titles: ["Shared"])).provenance, .exact)
        XCTAssertNotEqual(TaskSelectionResolver.resolve(tasks: tasks, evidence: .selected(ids: ["older", "newer"], titles: [])).provenance, .exact)
    }
    func testUnknownSelectedIDAndNoTasksDegradeSafely() {
        XCTAssertNil(TaskSelectionResolver.resolve(tasks: tasks, evidence: .selected(ids: ["missing"], titles: [])).threadID)
        XCTAssertNil(TaskSelectionResolver.resolve(tasks: [], evidence: .unavailable(.noData)).threadID)
    }
}
