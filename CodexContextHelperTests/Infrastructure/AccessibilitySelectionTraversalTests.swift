import XCTest
@testable import CodexContextHelper

final class AccessibilitySelectionTraversalTests: XCTestCase {
    func testExplicitAccessibilityLabelAndTitleFallbackAreBounded() {
        XCTAssertEqual(AccessibilitySelectionTraversal.taskTitle(title: "", description: "Desktop task"), "Desktop task")
        XCTAssertEqual(AccessibilitySelectionTraversal.taskTitle(title: "Task", description: nil), "Task")
        XCTAssertNil(AccessibilitySelectionTraversal.taskTitle(title: " ", description: String(repeating: "x", count: 513)))
        XCTAssertNil(AccessibilitySelectionTraversal.taskTitle(title: "line\nbreak", description: nil))
    }
    func testEmptySelectedChildrenStillSearchesOrdinaryChildren() throws {
        let routes = try XCTUnwrap(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { [] }, children: { ["task-list"] },
            selected: false, foundIdentity: false, pendingCount: 0
        ))
        XCTAssertEqual(routes.map(\.0), ["task-list"])
        XCTAssertEqual(routes.map(\.1), [false])
    }

    func testSelectedWrapperCarriesSelectionToIdentifyingControl() throws {
        let selectedWrapper = try XCTUnwrap(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { ["wrapper"] }, children: { XCTFail("Selected children take precedence"); return [] },
            selected: false, foundIdentity: false, pendingCount: 0
        ))
        let control = try XCTUnwrap(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { nil }, children: { ["task-button"] },
            selected: selectedWrapper[0].1, foundIdentity: false, pendingCount: 0
        ))
        XCTAssertEqual(control.map(\.0), ["task-button"])
        XCTAssertEqual(control.map(\.1), [true])
    }

    func testIdentifiedTaskDoesNotVisitItsNestedActionButtons() throws {
        let routes: [(String, Bool)] = try XCTUnwrap(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { XCTFail("Do not read descendants of an identified task"); return ["archive"] },
            children: { XCTFail("Do not read descendants of an identified task"); return ["rename"] },
            selected: true, foundIdentity: true, pendingCount: 0
        ))
        XCTAssertTrue(routes.isEmpty)
    }

    func testChildLimitsRejectIncompleteSelectionEvidence() {
        XCTAssertNil(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { Array(0..<21) }, children: { [] },
            selected: false, foundIdentity: false, pendingCount: 0
        ))
        XCTAssertNil(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { [1, 2] }, children: { [] },
            selected: false, foundIdentity: false, pendingCount: 399
        ))
        XCTAssertNil(AccessibilitySelectionTraversal.childRoutes(
            selectedChildren: { nil }, children: { [1, 2] },
            selected: false, foundIdentity: false, pendingCount: 399
        ))
    }
}
