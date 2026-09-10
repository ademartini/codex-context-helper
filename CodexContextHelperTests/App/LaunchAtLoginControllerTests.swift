import ServiceManagement
import XCTest
@testable import CodexContextHelper

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testSynchronizationNeverRegistersFromSavedPreference() {
        let store = LoginTestSettingsStore()
        store.settings.launchAtLogin = true
        let model = PanelViewModel(settingsStore: store)
        let service = LoginTestRegistration(status: .notRegistered)
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.synchronize()
        XCTAssertFalse(model.settings.launchAtLogin)
        XCTAssertFalse(store.settings.launchAtLogin)
        XCTAssertEqual(model.loginStatus, "Off")
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testExplicitOptInAndOptOutPersistConfirmedState() {
        let store = LoginTestSettingsStore()
        let model = PanelViewModel(settingsStore: store)
        let service = LoginTestRegistration(status: .notRegistered)
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(store.settings.launchAtLogin)
        XCTAssertEqual(model.loginStatus, "On")
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(store.settings.launchAtLogin)
        XCTAssertEqual(model.loginStatus, "Off")
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testExternalRevocationAndApprovalAreReflectedWithoutRegistering() {
        let model = PanelViewModel(settingsStore: LoginTestSettingsStore())
        let service = LoginTestRegistration(status: .enabled)
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.synchronize()
        XCTAssertTrue(model.settings.launchAtLogin)
        service.status = .requiresApproval
        controller.synchronize()
        XCTAssertFalse(model.settings.launchAtLogin)
        XCTAssertTrue(model.loginStatus.contains("Requires approval"))
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertFalse(model.settings.launchAtLogin)
        service.status = .enabled
        controller.synchronize()
        XCTAssertTrue(model.settings.launchAtLogin)
    }

    func testPendingApprovalCanBeUnregisteredExplicitly() {
        let model = PanelViewModel(settingsStore: LoginTestSettingsStore())
        let service = LoginTestRegistration(status: .requiresApproval)
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertFalse(model.settings.launchAtLogin)
    }

    func testRegistrationFailureDoesNotPersistOptIn() {
        let store = LoginTestSettingsStore()
        let model = PanelViewModel(settingsStore: store)
        let service = LoginTestRegistration(status: .notRegistered)
        service.fails = true
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.setEnabled(true)
        XCTAssertFalse(store.settings.launchAtLogin)
        XCTAssertTrue(model.loginStatus.contains("Could not change registration"))
    }

    func testUnregistrationFailureRetainsActualEnabledState() {
        let store = LoginTestSettingsStore()
        let model = PanelViewModel(settingsStore: store)
        let service = LoginTestRegistration(status: .enabled)
        service.fails = true
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.setEnabled(false)
        XCTAssertTrue(store.settings.launchAtLogin)
        XCTAssertTrue(model.loginStatus.hasPrefix("On"))
        XCTAssertTrue(model.loginStatus.contains("Could not change registration"))
    }

    func testMissingServiceIsUnavailableAndCanRecoverOnExplicitOptIn() {
        let model = PanelViewModel(settingsStore: LoginTestSettingsStore())
        let service = LoginTestRegistration(status: .notFound)
        let controller = LaunchAtLoginController(model: model, registration: service)
        controller.synchronize()
        XCTAssertFalse(model.settings.launchAtLogin)
        XCTAssertTrue(model.loginStatus.hasPrefix("Unavailable"))
        controller.setEnabled(true)
        XCTAssertTrue(model.settings.launchAtLogin)
        XCTAssertEqual(service.registerCalls, 1)
    }
}

@MainActor
private final class LoginTestSettingsStore: SettingsStoring {
    var settings = MonitorSettings()
    func load() -> MonitorSettings { settings }
    func save(_ settings: MonitorSettings) { self.settings = settings }
}

@MainActor
private final class LoginTestRegistration: LoginItemRegistering {
    var status: SMAppService.Status
    var fails = false
    var registerCalls = 0
    var unregisterCalls = 0
    init(status: SMAppService.Status) { self.status = status }
    func register() throws {
        registerCalls += 1
        if fails { throw Failure.injected }
        status = .enabled
    }
    func unregister() throws {
        unregisterCalls += 1
        if fails { throw Failure.injected }
        status = .notRegistered
    }
    private enum Failure: Error { case injected }
}
