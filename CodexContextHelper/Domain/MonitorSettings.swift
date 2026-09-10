import Foundation

struct PanelPosition: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
}

struct ApprovedExecutable: Equatable, Codable, Sendable {
    var path: String
    var identity: String
    var version: String
    var launcherPATH: String?
}

struct MonitorSettings: Equatable, Sendable {
    static let currentVersion = 2
    var recentTaskCount: Int = 5
    var panelPosition: PanelPosition?
    var isExpanded: Bool = false
    var launchAtLogin: Bool = false
    var includeSubagents: Bool = false
    var approvedExecutable: ApprovedExecutable?

    mutating func normalize() {
        recentTaskCount = min(10, max(1, recentTaskCount))
        if let panelPosition, !panelPosition.x.isFinite || !panelPosition.y.isFinite { self.panelPosition = nil }
    }
}
