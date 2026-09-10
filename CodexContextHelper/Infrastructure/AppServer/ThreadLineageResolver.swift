import Foundation

enum ThreadLineageResolver {
    /// Backend thread-local cost semantics require live characterization, separate from token counters.
    static let costIsThreadLocal = false

    static func rollup(root: TaskSummary, lineage: ThreadLineage, contexts: [String: Metric<ContextSnapshot>],
                       costs: [String: Metric<TaskCostEstimate>], costIsThreadLocal: Bool = false) -> AgentRollup {
        let tasks = Dictionary(([root] + lineage.tasks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids: Set<String> = [root.id]
        var changed = true
        while changed {
            let before = ids.count
            for task in tasks.values {
                if let parent = task.parentThreadID, ids.contains(parent) { ids.insert(task.id) }
            }
            changed = before != ids.count
        }
        let exhaustive = lineage.exhaustive && ids.count == tasks.count
        let tokenValues: [(TokenCounters, DataProvenance)] = ids.compactMap { id in
            guard case .available(let context, let provenance) = contexts[id] else { return nil }
            return (context.cumulative, provenance)
        }
        let estimates: [(TaskCostEstimate, DataProvenance)] = ids.compactMap { id in
            guard case .available(let cost, let provenance) = costs[id], cost.threadID == id else { return nil }
            return (cost, provenance)
        }
        let tokenSum = tokenValues.reduce(Optional(TokenCounters.zero)) { $0?.adding($1.0) }
        let tokens: CoveredMetric<TokenCounters> = covered(value: tokenSum, provenance: tokenValues.map(\.1),
                                                         discovered: ids.count, exhaustive: exhaustive, estimated: false)
        let credits: CoveredMetric<Int64>, usd: CoveredMetric<Int64>
        if costIsThreadLocal {
            credits = covered(value: sum(estimates.map { $0.0.creditMicros }), provenance: estimates.map(\.1),
                              discovered: ids.count, exhaustive: exhaustive, estimated: true)
            let dollars = estimates.compactMap { pair -> (Int64, DataProvenance)? in pair.0.usdMicros.map { ($0, pair.1) } }
            usd = covered(value: sum(dollars.map(\.0)), provenance: dollars.map(\.1),
                          discovered: ids.count, exhaustive: exhaustive, estimated: true)
        } else {
            credits = CoveredMetric(metric: .unavailable(.unsupportedInclusiveCost), coverage: RollupCoverage(included: 0, discovered: ids.count, lineageExhaustive: exhaustive)!)
            usd = credits
        }
        return AgentRollup(rootThreadID: root.id, threadIDs: ids, tokens: tokens, creditMicros: credits, usdMicros: usd)
    }
    private static func sum(_ numbers: [Int64]) -> Int64? {
        numbers.reduce(Optional(Int64(0))) { result, next in
            guard let result else { return nil }
            let sum = result.addingReportingOverflow(next)
            return sum.overflow ? nil : sum.partialValue
        }
    }
    private static func covered<Value: Equatable & Sendable>(value: Value?, provenance: [DataProvenance], discovered: Int, exhaustive: Bool, estimated: Bool) -> CoveredMetric<Value> {
        let included = value == nil ? 0 : provenance.count
        let coverage = RollupCoverage(included: included, discovered: discovered, lineageExhaustive: exhaustive)!
        guard let value, !provenance.isEmpty else { return CoveredMetric(metric: .unavailable(.noData), coverage: coverage) }
        var source = DataProvenance(source: .derived, schemaVersion: CodexProtocol.schemaVersion,
                                    observedAt: provenance.map(\.observedAt).min()!, measurement: estimated ? .backendEstimated : .exact)
        source.invalidated = provenance.contains { $0.invalidated }
        return CoveredMetric(metric: .available(value, source), coverage: coverage)
    }
}
