import Foundation

enum TaskActivity: String, Codable, Sendable { case active, idle, completed, unknown }

struct TaskSummary: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var updatedAt: Date
    var recencyAt: Date?
    var model: String?
    var activity: TaskActivity = .unknown
    var parentThreadID: String?
    var sessionPath: String?
    var agentName: String?
}

struct TaskSnapshot: Equatable, Sendable, Identifiable {
    var task: TaskSummary
    var context: Metric<ContextSnapshot> = .unavailable(.noData)
    var cost: Metric<TaskCostEstimate> = .unavailable(.noData)
    var id: String { task.id }
}

struct AgentDiscoverySnapshot: Equatable, Sendable {
    var rootID: String
    var tasks: [TaskSnapshot]
    var exhaustive: Bool
    var reportingCount: Int { tasks.filter { $0.context.value != nil }.count }
    var totalTokens: Int64? {
        guard reportingCount > 0 else { return nil }
        return tasks.compactMap { $0.context.value?.cumulative.total }.reduce(Optional(Int64(0))) { result, next in
            guard let result else { return nil }
            let sum = result.addingReportingOverflow(next)
            return sum.overflow ? nil : sum.partialValue
        }
    }
    var coverageNote: String {
        if reportingCount < tasks.count { return " · \(reportingCount)/\(tasks.count) reporting" }
        return exhaustive ? "" : " · partial"
    }
}
