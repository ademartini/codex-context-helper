import Foundation

struct TaskCostGroup: Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var speed: String?
    var tokenType: String?
    var tokens: Int64?
    var creditMicros: Int64?
    var usdMicros: Int64?
    var inputTokens: Int64?
    var cachedInputTokens: Int64?
    var netNewInputTokens: Int64?
    var outputTokens: Int64?
    var totalTokens: Int64?
}

struct TaskCostEstimate: Equatable, Sendable {
    let threadID: String
    let creditMicros: Int64
    let usdMicros: Int64?
    let groups: [TaskCostGroup]
    var measurement: MeasurementKind { .backendEstimated }
    var credits: Decimal { Decimal(creditMicros) / 1_000_000 }
    var estimatedUSD: Decimal? { usdMicros.map { Decimal($0) / 1_000_000 } }

    init?(threadID: String, creditMicros: Int64, usdMicros: Int64?, groups: [TaskCostGroup] = []) {
        guard !threadID.isEmpty, creditMicros >= 0, usdMicros.map({ $0 >= 0 }) ?? true,
              groups.allSatisfy({ group in
                  [group.tokens, group.creditMicros, group.usdMicros, group.inputTokens,
                   group.cachedInputTokens, group.netNewInputTokens, group.outputTokens,
                   group.totalTokens].allSatisfy { $0.map { $0 >= 0 } ?? true }
              }) else { return nil }
        self.threadID = threadID; self.creditMicros = creditMicros; self.usdMicros = usdMicros; self.groups = groups
    }
}

struct RollupCoverage: Equatable, Sendable {
    let included: Int
    let discovered: Int
    let lineageExhaustive: Bool
    var unavailable: Int { discovered - included }
    var isComplete: Bool { lineageExhaustive && discovered > 0 && included == discovered }
    var label: String { "\(included) of \(discovered) tasks" + (lineageExhaustive ? (isComplete ? " · complete" : " · partial") : " · known tasks only") }

    init?(included: Int, discovered: Int, lineageExhaustive: Bool) {
        guard included >= 0, discovered >= included else { return nil }
        self.included = included; self.discovered = discovered; self.lineageExhaustive = lineageExhaustive
    }
}

struct CoveredMetric<Value: Equatable & Sendable>: Equatable, Sendable {
    var metric: Metric<Value>
    var coverage: RollupCoverage
}

struct AgentRollup: Equatable, Sendable {
    var rootThreadID: String
    var threadIDs: Set<String>
    var tokens: CoveredMetric<TokenCounters>
    var creditMicros: CoveredMetric<Int64>
    var usdMicros: CoveredMetric<Int64>
}
