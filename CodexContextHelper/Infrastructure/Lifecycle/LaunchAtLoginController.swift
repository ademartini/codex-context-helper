import ServiceManagement

/// Narrow platform boundary keeps tests from changing the user's actual login items.
@MainActor
protocol LoginItemRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct MainAppLoginItemRegistration: LoginItemRegistering {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLoginController {
    private let model: PanelViewModel
    private let registration: any LoginItemRegistering

    init(model: PanelViewModel, registration: any LoginItemRegistering = MainAppLoginItemRegistration()) {
        self.model = model
        self.registration = registration
    }

    /// The system is authoritative, including changes made outside this app.
    /// Restoring a saved preference must never silently register a login item.
    func synchronize() {
        let status = registration.status
        model.settings.launchAtLogin = status == .enabled
        model.loginStatus = label(for: status)
        model.persist()
    }

    func setEnabled(_ enabled: Bool) {
        let current = registration.status
        do {
            if enabled {
                if current == .notRegistered || current == .notFound { try registration.register() }
                // A registered item whose approval was revoked must be re-enabled by
                // the user in System Settings. Re-registering cannot grant that approval.
            } else if current == .enabled || current == .requiresApproval {
                try registration.unregister()
            }
            synchronize()
        } catch {
            // Even a failed request can leave system state changed. Never optimistically
            // persist the requested value or retain localized OS errors in diagnostics.
            synchronize()
            model.loginStatus += " · Could not change registration. Check System Settings → General → Login Items."
        }
    }

    private func label(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "On"
        case .notRegistered: "Off"
        case .requiresApproval: "Off · Requires approval in System Settings → General → Login Items"
        case .notFound: "Unavailable · Run the signed application from a stable location"
        @unknown default: "Unavailable · Unrecognized system registration state"
        }
    }
}
