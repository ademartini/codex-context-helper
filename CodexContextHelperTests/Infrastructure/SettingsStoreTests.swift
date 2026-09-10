import XCTest
@testable import CodexContextHelper

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func withStore(_ body: (SettingsStore, UserDefaults) -> Void) {
        let suite = "CodexContextHelperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(SettingsStore(defaults: defaults), defaults)
    }

    func testAbsentPreferencesUseDefaults() {
        withStore { store, _ in XCTAssertEqual(store.load(), MonitorSettings()) }
    }

    func testRoundTripPreservesPreferences() {
        withStore { store, _ in
            let settings = MonitorSettings(recentTaskCount: 8, panelPosition: PanelPosition(x: 12, y: 34), isExpanded: true, launchAtLogin: true)
            store.save(settings)
            XCTAssertEqual(store.load(), settings)
        }
    }

    func testMalformedFieldDoesNotDiscardValidFields() {
        withStore { store, defaults in
            defaults.set(["version": 2, "recentTaskCount": "five", "isExpanded": true, "launchAtLogin": "true", "panelPosition": ["x": 40, "y": 50]], forKey: "monitor.settings")
            let settings = store.load()
            XCTAssertEqual(settings.recentTaskCount, 5)
            XCTAssertTrue(settings.isExpanded)
            XCTAssertFalse(settings.launchAtLogin)
            XCTAssertEqual(settings.panelPosition, PanelPosition(x: 40, y: 50))
        }
    }

    func testMigrationPreservesPositionRecencyAndLoginChoice() {
        withStore { store, defaults in
            defaults.set(["version": 1, "recentTaskCount": 7, "launchAtLogin": true, "panelX": 120, "panelY": 240], forKey: "monitor.settings")
            let settings = store.load()
            XCTAssertEqual(settings.recentTaskCount, 7)
            XCTAssertTrue(settings.launchAtLogin)
            XCTAssertEqual(settings.panelPosition, PanelPosition(x: 120, y: 240))
            XCTAssertEqual(defaults.dictionary(forKey: "monitor.settings")?["version"] as? Int, 2)
        }
    }

    func testBoundsAndPrivacyAllowlist() {
        withStore { store, defaults in
            defaults.set(["version": 1, "recentTaskCount": 99, "rawPrompt": "SENSITIVE_FIXTURE"], forKey: "monitor.settings")
            XCTAssertEqual(store.load().recentTaskCount, 10)
            XCTAssertNil(defaults.dictionary(forKey: "monitor.settings")?["rawPrompt"])
        }
    }
}
