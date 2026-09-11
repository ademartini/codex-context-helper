import XCTest

final class FloatingPanelUITests: XCTestCase {
    @MainActor
    func testTaskHistoryDetailAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["panel.history"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["task.details"].exists)
        app.buttons["panel.history"].click()
        XCTAssertTrue(app.buttons["panel.back"].waitForExistence(timeout: 3))
        app.buttons["panel.back"].click()
        app.buttons["task.details"].click()
        XCTAssertTrue(app.buttons["panel.back"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["task.details"].waitForExistence(timeout: 3))
        app.buttons["panel.settings"].click()
        XCTAssertTrue(app.staticTexts["Account limits & history"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["settings.executable"].exists, "Manual executable entry starts under Choose CLI installation")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sanitized settings view"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
