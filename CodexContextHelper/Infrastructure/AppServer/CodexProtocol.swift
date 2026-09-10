import Foundation

/// Only this locally characterized metadata schema is decoded. Unknown fields are discarded.
enum CodexProtocol {
    static let schemaVersion = "app-server-v2-2026-09-09"
    static let interactiveSourceKinds = ["cli", "vscode", "exec", "appServer"]
    static let sourceKinds = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]

    struct ThreadPage: Sendable {
        var tasks: [TaskSummary]
        var nextCursor: String?
    }

    static func threadPage(_ value: JSONValue) throws -> ThreadPage {
        let object = try object(value)
        guard case .array(let rows) = object["data"] else { throw AppServerError.malformedResponse }
        return try ThreadPage(tasks: rows.map(thread), nextCursor: optionalString(object, "nextCursor"))
    }

    static func thread(_ value: JSONValue) throws -> TaskSummary {
        let object = try object(value)
        let id = try requiredString(object, "id")
        guard !id.isEmpty else { throw AppServerError.malformedResponse }
        let updated = try nonnegative(object, "updatedAt", required: true)!
        let recency = try nonnegative(object, "recencyAt")
        var activity: TaskActivity = .unknown
        if let raw = object["status"], raw != .null {
            let status = try self.object(raw)
            switch try requiredString(status, "type") {
            case "active": activity = .active
            case "idle": activity = .idle
            default: activity = .unknown
            }
        }
        let name = try optionalString(object, "name")
        return try TaskSummary(
            id: id, title: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled task",
            updatedAt: Date(timeIntervalSince1970: Double(updated)),
            recencyAt: recency.map { Date(timeIntervalSince1970: Double($0)) },
            model: optionalString(object, "model"), activity: activity,
            parentThreadID: optionalString(object, "parentThreadId"), sessionPath: optionalString(object, "path")
        )
    }

    /// Only the authentication discriminator survives this function; never retain account identity.
    static func requireSignedIn(_ value: JSONValue) throws {
        let fields = try object(value)
        guard let account = fields["account"], account != .null else { throw AppServerError.signedOut }
        let accountFields = try object(account)
        guard ["chatgpt", "apiKey", "amazonBedrock"].contains(try requiredString(accountFields, "type")) else {
            throw AppServerError.malformedResponse
        }
    }

    static func quotas(_ value: JSONValue) throws -> [QuotaBucket]? {
        let fields = try object(value)
        let buckets: [String: JSONValue]
        if let multiple = fields["rateLimitsByLimitId"], multiple != .null {
            buckets = try object(multiple)
        } else if let legacy = fields["rateLimits"], legacy != .null {
            let values = try object(legacy)
            buckets = [try optionalString(values, "limitId") ?? "account": legacy]
        } else { return nil }
        let result = buckets.keys.sorted().map { key -> QuotaBucket in
            guard let bucket = try? object(buckets[key]!) else {
                return QuotaBucket(id: key, name: key, windows: [], unavailableWindows: ["primary", "secondary"])
            }
            var windows: [QuotaWindow] = []
            var unavailable: [String] = []
            for slot in ["primary", "secondary"] {
                guard let raw = bucket[slot], raw != .null else { continue }
                do {
                    let window = try object(raw)
                    let used = try nonnegative(window, "usedPercent", required: true)!
                    let duration = try nonnegative(window, "windowDurationMins")
                    let reset = try nonnegative(window, "resetsAt")
                    guard used <= 100, duration.map({ $0 > 0 && $0 <= Int.max }) ?? true else { throw AppServerError.malformedResponse }
                    windows.append(QuotaWindow(id: slot, usedPercentage: Double(used), windowDurationMinutes: duration.map(Int.init), resetsAt: reset.map { Date(timeIntervalSince1970: Double($0)) }))
                } catch { unavailable.append(slot) }
            }
            return QuotaBucket(id: key, name: (try? optionalString(bucket, "limitName")) ?? key, windows: windows, unavailableWindows: unavailable)
        }
        return result.contains(where: { !$0.windows.isEmpty || !$0.unavailableWindows.isEmpty }) ? result : nil
    }

    static func dailyUsage(_ value: JSONValue) throws -> [DailyTokenUsage]? {
        let fields = try object(value)
        guard let raw = fields["dailyUsageBuckets"], raw != .null else { return nil }
        guard case .array(let rows) = raw else { throw AppServerError.malformedResponse }
        var seen = Set<String>()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return try rows.map { row in
            let values = try object(row)
            let day = try requiredString(values, "startDate")
            guard day.count == 10, let date = formatter.date(from: day), formatter.string(from: date) == day,
                  seen.insert(day).inserted else { throw AppServerError.malformedResponse }
            return try DailyTokenUsage(day: day, tokens: nonnegative(values, "tokens", required: true)!)
        }.sorted { $0.day < $1.day }
    }

    static func taskCost(_ value: JSONValue, threadID: String) throws -> TaskCostEstimate? {
        let fields = try object(value)
        guard let raw = fields["threadUsage"], raw != .null else { return nil }
        let usage = try object(raw)
        guard try requiredString(usage, "threadId") == threadID,
              case .array(let rows) = usage["groups"] else { throw AppServerError.malformedResponse }
        let groups = try rows.map { raw in
            let group = try object(raw)
            return try TaskCostGroup(
                model: optionalString(group, "model"), reasoningEffort: optionalString(group, "reasoningEffort"),
                speed: optionalString(group, "speed"), tokenType: optionalString(group, "tokenType"),
                tokens: nonnegative(group, "tokens"), creditMicros: nonnegative(group, "estimatedUsageCreditsMicros", required: true),
                usdMicros: nonnegative(group, "estimatedUsageUsdMicros"), inputTokens: nonnegative(group, "inputTokens"),
                cachedInputTokens: nonnegative(group, "cachedInputTokens"), netNewInputTokens: nonnegative(group, "netNewInputTokens"),
                outputTokens: nonnegative(group, "outputTokens"), totalTokens: nonnegative(group, "totalTokens")
            )
        }
        guard let result = try TaskCostEstimate(threadID: threadID,
            creditMicros: nonnegative(usage, "estimatedUsageCreditsMicros", required: true)!,
            usdMicros: nonnegative(usage, "estimatedUsageUsdMicros"), groups: groups) else { throw AppServerError.malformedResponse }
        return result
    }

    private static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = value else { throw AppServerError.malformedResponse }
        return fields
    }
    private static func optionalString(_ fields: [String: JSONValue], _ key: String) throws -> String? {
        guard let raw = fields[key], raw != .null else { return nil }
        guard case .string(let value) = raw else { throw AppServerError.malformedResponse }
        return value
    }
    private static func requiredString(_ fields: [String: JSONValue], _ key: String) throws -> String {
        guard let value = try optionalString(fields, key) else { throw AppServerError.malformedResponse }
        return value
    }
    private static func nonnegative(_ fields: [String: JSONValue], _ key: String, required: Bool = false) throws -> Int64? {
        guard let raw = fields[key], raw != .null else {
            if required { throw AppServerError.malformedResponse }
            return nil
        }
        guard case .integer(let value) = raw, value >= 0 else { throw AppServerError.malformedResponse }
        return value
    }
}
