import XCTest
@testable import CodexContextHelper

@MainActor
final class AccessibilityPermissionControllerTests: XCTestCase {
    func testCheckingPermissionNeverPromptsAndRevocationIsObserved() {
        var granted = false, prompts = 0
        let controller = AccessibilityPermissionController(check: { granted }, prompt: { prompts += 1; return granted })
        XCTAssertFalse(controller.isGranted); XCTAssertEqual(prompts, 0)
        controller.requestFromSettings(); XCTAssertEqual(prompts, 1)
        granted = true; XCTAssertTrue(controller.isGranted)
        granted = false; XCTAssertFalse(controller.isGranted)
        XCTAssertEqual(prompts, 1)
    }
}
