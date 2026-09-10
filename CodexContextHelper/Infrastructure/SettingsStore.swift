import Foundation
import CoreFoundation

@MainActor
protocol SettingsStoring {
    func load() -> MonitorSettings
    func save(_ settings: MonitorSettings)
}

/// Persists only a fixed allowlist of non-content preferences. Never stores task or account snapshots.
@MainActor
final class SettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "monitor.settings") {
        self.defaults = defaults; self.key = key
    }

    func load() -> MonitorSettings {
        guard let values = defaults.dictionary(forKey: key) else { return MonitorSettings() }
        var settings = MonitorSettings()
        // Read each setting independently so one malformed value does not discard valid preferences.
        if let count = integer(values["recentTaskCount"]) { settings.recentTaskCount = count }
        settings.isExpanded = boolean(values["isExpanded"]) ?? false
        settings.launchAtLogin = boolean(values["launchAtLogin"]) ?? false
        settings.includeSubagents = boolean(values["includeSubagents"]) ?? false
        if let position = values["panelPosition"] as? [String: Any],
           let x = number(position["x"]), let y = number(position["y"]) {
            settings.panelPosition = PanelPosition(x: x, y: y)
        } else if let x = number(values["panelX"]), let y = number(values["panelY"]) {
            settings.panelPosition = PanelPosition(x: x, y: y)
        }
        if let executable = values["approvedExecutable"] as? [String: String],
           let path = executable["path"], path.hasPrefix("/"),
           let identity = executable["identity"], !identity.isEmpty,
           let version = executable["version"], !version.isEmpty {
            settings.approvedExecutable = ApprovedExecutable(path: path, identity: identity, version: version, launcherPATH: executable["launcherPATH"])
        }
        settings.normalize()
        if integer(values["version"]) ?? 1 < MonitorSettings.currentVersion { save(settings) }
        return settings
    }

    func save(_ input: MonitorSettings) {
        var settings = input
        settings.normalize()
        var values: [String: Any] = ["version": MonitorSettings.currentVersion,
            "recentTaskCount": settings.recentTaskCount, "isExpanded": settings.isExpanded,
            "launchAtLogin": settings.launchAtLogin, "includeSubagents": settings.includeSubagents]
        if let position = settings.panelPosition { values["panelPosition"] = ["x": position.x, "y": position.y] }
        if let executable = settings.approvedExecutable {
            var entry = ["path": executable.path, "identity": executable.identity, "version": executable.version]
            if let launcherPATH = executable.launcherPATH { entry["launcherPATH"] = launcherPATH }
            values["approvedExecutable"] = entry
        }
        defaults.set(values, forKey: key)
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number, let result = Int(exactly: number) else { return nil }
        return result
    }
}
