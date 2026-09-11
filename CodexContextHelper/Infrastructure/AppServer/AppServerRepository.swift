import Foundation

struct ThreadLineage: Equatable, Sendable {
    /// Includes the root if its metadata could be read, plus uniquely identified descendants.
    var tasks: [TaskSummary]
    var exhaustive: Bool
}

actor AppServerRepository {
    private let connection: any AppServerRequesting
    private let maximumKnownTasks: Int
    private var descendantFilterRejected = false

    init(connection: any AppServerRequesting, maximumKnownTasks: Int = 200) {
        self.connection = connection
        self.maximumKnownTasks = min(200, max(1, maximumKnownTasks))
    }

    func recentTasks(count: Int) async throws -> [TaskSummary] {
        let requested = min(maximumKnownTasks, max(1, count))
        let result = try await catalog(archived: false, count: requested)
        return Array(result.tasks.sorted {
            let left = $0.recencyAt ?? $0.updatedAt, right = $1.recencyAt ?? $1.updatedAt
            return left == right ? $0.id < $1.id : left > right
        }.prefix(requested))
    }

    func selectedTask(id: String) async throws -> TaskSummary {
        let response = try await connection.request(method: "thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(false)]))
        guard let raw = response["thread"] else { throw AppServerError.malformedResponse }
        let task = try CodexProtocol.thread(raw)
        guard task.id == id else { throw AppServerError.malformedResponse }
        return task
    }

    func matchingTitle(_ title: String) async throws -> ThreadLineage {
        var known: [String: TaskSummary] = [:]
        var exhaustive = true
        for archived in [false, true] {
            guard known.count < maximumKnownTasks else {
                exhaustive = false
                break
            }
            let page = try await catalog(archived: archived, count: maximumKnownTasks - known.count, title: title)
            exhaustive = exhaustive && page.exhaustive
            for task in page.tasks { known[task.id] = task }
        }
        return ThreadLineage(tasks: known.values.filter { $0.title == title }.sorted { $0.id < $1.id }, exhaustive: exhaustive)
    }

    func accountUsage() async -> AccountUsageSnapshot {
        do {
            try CodexProtocol.requireSignedIn(await connection.request(method: "account/read", params: .object(["refreshToken": .bool(false)])))
        } catch {
            let reason = Self.reason(error)
            return AccountUsageSnapshot(quotas: .unavailable(reason), dailyTokens: .unavailable(reason))
        }
        // Independent capabilities degrade separately (older versions may lack account/usage/read).
        async let quotas: Metric<[QuotaBucket]> = readQuotas()
        async let daily: Metric<[DailyTokenUsage]> = readDailyUsage()
        return await AccountUsageSnapshot(quotas: quotas, dailyTokens: daily)
    }

    func taskCost(threadID: String) async -> Metric<TaskCostEstimate> {
        guard !threadID.isEmpty else { return .unavailable(.noData) }
        do {
            let value = try await connection.request(method: "account/usage/read", params: .object(["threadId": .string(threadID)]))
            guard let estimate = try CodexProtocol.taskCost(value, threadID: threadID) else { return .unavailable(.noData) }
            return .available(estimate, provenance(measurement: .backendEstimated))
        } catch { return .unavailable(Self.reason(error)) }
    }

    func descendants(rootID: String) async throws -> ThreadLineage {
        guard !rootID.isEmpty else { return ThreadLineage(tasks: [], exhaustive: false) }
        var known: [String: TaskSummary] = [:]
        var exhaustive = true
        do {
            let value = try await connection.request(method: "thread/read", params: .object(["threadId": .string(rootID), "includeTurns": .bool(false)]))
            guard let raw = value["thread"] else { throw AppServerError.malformedResponse }
            let root = try CodexProtocol.thread(raw)
            guard root.id == rootID else { throw AppServerError.malformedResponse }
            known[root.id] = root
        } catch { exhaustive = false }
        for archived in [false, true] {
            guard known.count < maximumKnownTasks else { exhaustive = false; break }
            do {
                let page = try await catalog(archived: archived, count: maximumKnownTasks - known.count, ancestorID: rootID)
                exhaustive = exhaustive && page.exhaustive
                for task in page.tasks { known[task.id] = task }
            } catch {
                // Preserve known rows but never imply discovery completed after a failed page.
                exhaustive = false
            }
        }
        // Validate explicit lineage rather than including unrelated rows from a future/misbehaving server.
        var included: Set<String> = [rootID]
        var changed = true
        while changed {
            changed = false
            for task in known.values where !included.contains(task.id) {
                if let parent = task.parentThreadID, included.contains(parent) {
                    included.insert(task.id); changed = true
                }
            }
        }
        if known.keys.contains(where: { !included.contains($0) }) { exhaustive = false }
        return ThreadLineage(tasks: known.values.filter { included.contains($0.id) }.sorted { $0.id < $1.id }, exhaustive: exhaustive)
    }

    private func catalog(archived: Bool, count: Int, ancestorID: String? = nil, title: String? = nil) async throws -> ThreadLineage {
        // Parameter rejection applies only to descendant discovery, never ordinary task listing.
        if ancestorID != nil, descendantFilterRejected { return ThreadLineage(tasks: [], exhaustive: false) }
        var known: [String: TaskSummary] = [:]
        var cursor: String?
        var cursors = Set<String>()
        var pages = 0
        repeat {
            var params: [String: JSONValue] = [
                "limit": .integer(Int64(min(50, count - known.count))), "archived": .bool(archived),
                "sortKey": .string("recency_at"), "sortDirection": .string("desc"),
                "sourceKinds": .array((ancestorID == nil ? CodexProtocol.interactiveSourceKinds : CodexProtocol.sourceKinds).map(JSONValue.string)), "useStateDbOnly": .bool(true)
            ]
            if let title { params["searchTerm"] = .string(title) }
            if let cursor { params["cursor"] = .string(cursor) }
            if let ancestorID { params["ancestorThreadId"] = .string(ancestorID) }
            let page: CodexProtocol.ThreadPage
            do {
                let response = try await connection.request(method: "thread/list", params: .object(params))
                page = try CodexProtocol.threadPage(response)
            } catch {
                if ancestorID != nil {
                    if error as? AppServerError == .rejectedParameters { descendantFilterRejected = true }
                    return ThreadLineage(tasks: Array(known.values), exhaustive: false)
                }
                throw error
            }
            var droppedRows = false
            for task in page.tasks {
                if known.count < count || known[task.id] != nil { known[task.id] = task } else { droppedRows = true }
            }
            pages += 1
            cursor = page.nextCursor
            if cursor == nil {
                return ThreadLineage(tasks: Array(known.values), exhaustive: !droppedRows)
            }
            guard let cursor, cursors.insert(cursor).inserted, pages < 20, known.count < count else {
                return ThreadLineage(tasks: Array(known.values), exhaustive: false)
            }
        } while true
    }

    private func readQuotas() async -> Metric<[QuotaBucket]> {
        do {
            let value = try await connection.request(method: "account/rateLimits/read", params: .object([:]))
            guard let quotas = try CodexProtocol.quotas(value) else { return .unavailable(.noData) }
            return .available(quotas, provenance())
        } catch { return .unavailable(Self.reason(error)) }
    }

    private func readDailyUsage() async -> Metric<[DailyTokenUsage]> {
        do {
            let value = try await connection.request(method: "account/usage/read", params: .object([:]))
            guard let days = try CodexProtocol.dailyUsage(value), !days.isEmpty else { return .unavailable(.noData) }
            return .available(days, provenance())
        } catch { return .unavailable(Self.reason(error)) }
    }

    private func provenance(measurement: MeasurementKind = .exact) -> DataProvenance {
        DataProvenance(source: .appServer, schemaVersion: CodexProtocol.schemaVersion, measurement: measurement)
    }
    private static func reason(_ error: any Error) -> UnavailableReason {
        (error as? AppServerError)?.unavailableReason ?? .disconnected
    }
}
