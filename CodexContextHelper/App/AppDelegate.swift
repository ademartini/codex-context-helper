import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: PanelViewModel?
    private var panel: FloatingPanelController?
    private var menu: MenuBarController?
    private var coordinator: MonitorCoordinator?
    private var login: LaunchAtLoginController?

    func openSettings() { panel?.showSettings() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil || CommandLine.arguments.contains("--ui-testing") else { return }
        let model: PanelViewModel
        #if DEBUG
        if CommandLine.arguments.contains("--ui-testing") {
            let defaults = UserDefaults(suiteName: "io.github.ademartini.CodexContextHelper.UITests")!
            defaults.removePersistentDomain(forName: "io.github.ademartini.CodexContextHelper.UITests")
            model = PanelViewModel(settingsStore: SettingsStore(defaults: defaults))
            PreviewFixtures.populate(model)
        } else { model = PanelViewModel() }
        #else
        model = PanelViewModel()
        #endif
        let panel = FloatingPanelController(model: model)
        self.model = model; self.panel = panel
        menu = MenuBarController(model: model, panel: panel)
        #if DEBUG
        let fixtureMode = CommandLine.arguments.contains("--ui-testing")
        #else
        let fixtureMode = false
        #endif
        if !fixtureMode {
            let coordinator = MonitorCoordinator(model: model)
            self.coordinator = coordinator
            let login = LaunchAtLoginController(model: model)
            self.login = login; login.synchronize()
            model.onRefresh = { [weak coordinator] in coordinator?.refresh() }
            model.onExecutableApproved = { [weak coordinator] in coordinator?.executableApproved() }
            model.onLoginChange = { [weak login] enabled in login?.setEnabled(enabled) }
            coordinator.start()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(helperActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        model.onPreferencesChanged = { [weak panel] in panel?.updateLayout() }
        model.onDataPreferencesChanged = { [weak coordinator] in coordinator?.preferencesChanged() }
        model.onAgentNavigation = { [weak coordinator] in coordinator?.agentPageChanged() }
        model.onTaskTrackingChange = { [weak coordinator] in coordinator?.taskTrackingChanged() }
        model.onVisibilityChanged = { [weak panel] in panel?.updateVisibility() }
        panel.updateVisibility()
    }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        coordinator?.refresh()
    }
    @objc private func helperActivated() { coordinator?.refresh(); login?.synchronize() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        Task {
            let stopped = await coordinator.stop()
            if !stopped { model?.settingsMessage = "The local reader is still stopping. Try Quit again." }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}
