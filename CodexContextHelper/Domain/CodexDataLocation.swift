import Foundation

enum CodexDataLocation {
    static var home: URL { home(environment: ProcessInfo.processInfo.environment) }
    static var sessions: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    static func home(environment: [String: String], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment["CODEX_HOME"], path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }
}
