import Foundation

protocol MonitorBackend: TaskCostProviding {
    func start() async throws
    func close() async -> Bool
    func isConnected() async -> Bool
    func recentTasks(count: Int) async throws -> [TaskSummary]
    func selectedTask(id: String) async throws -> TaskSummary
    func matchingTitle(_ title: String) async throws -> ThreadLineage
    func accountUsage() async -> AccountUsageSnapshot
    func descendants(rootID: String) async throws -> ThreadLineage
}

actor LocalMonitorBackend: MonitorBackend {
    private let connection: JSONRPCConnection
    private let repository: AppServerRepository

    init(approved: ApprovedExecutable) async throws {
        let process = try await Task.detached(priority: .utility) { try AppServerProcess.make(approved: approved) }.value
        let connection = JSONRPCConnection(process: process)
        self.connection = connection
        repository = AppServerRepository(connection: connection)
    }
    func start() async throws { try await connection.start() }
    func close() async -> Bool { await connection.close() }
    func isConnected() async -> Bool { await connection.health == .connected }
    func recentTasks(count: Int) async throws -> [TaskSummary] { try await repository.recentTasks(count: count) }
    func selectedTask(id: String) async throws -> TaskSummary { try await repository.selectedTask(id: id) }
    func matchingTitle(_ title: String) async throws -> ThreadLineage { try await repository.matchingTitle(title) }
    func accountUsage() async -> AccountUsageSnapshot { await repository.accountUsage() }
    func descendants(rootID: String) async throws -> ThreadLineage { try await repository.descendants(rootID: rootID) }
    func taskCost(threadID: String) async -> Metric<TaskCostEstimate> { await repository.taskCost(threadID: threadID) }
}

struct ReconnectBackoff {
    private(set) var failures = 0
    mutating func failed() -> TimeInterval {
        let delay = min(30.0, pow(2, Double(min(failures, 5))))
        failures = min(failures + 1, 6)
        return delay
    }
    mutating func reset() { failures = 0 }
}
