#if DEBUG
import Foundation

@MainActor
enum PreviewFixtures {
    static func populate(_ model: PanelViewModel) {
        model.settings = MonitorSettings()
        let source = DataProvenance(source: .sessionLog, schemaVersion: "sanitized-fixture", counterAt: Date())
        let counters = TokenCounters(input: 55_000, cachedInput: 30_000, output: 1_000, reasoningOutput: 200, total: 56_000)!
        let cumulative = TokenCounters(input: 80_000, cachedInput: 50_000, output: 20_000, reasoningOutput: 4_000, total: 100_000)!
        let root = TaskSummary(id: "fixture-root", title: "Fixture task", updatedAt: Date(), model: "Fixture model", activity: .active)
        let unavailable = TaskSummary(id: "fixture-unavailable", title: "Unavailable task", updatedAt: Date(), model: nil)
        model.tasks = [TaskSnapshot(task: root, context: .available(ContextSnapshot(latestResponse: counters, cumulative: cumulative, modelContextWindow: 100_000)!, source),
                                   cost: .available(TaskCostEstimate(threadID: root.id, creditMicros: 1_234_567, usdMicros: nil)!, source)), TaskSnapshot(task: unavailable)]
        model.selection = TaskSelection(threadID: root.id, provenance: .exact)
        model.connectionIssue = nil
        model.account = AccountUsageSnapshot(quotas: .available([
            QuotaBucket(id: "fixture-a", name: "Standard quota", windows: [QuotaWindow(id: "primary", usedPercentage: 45, windowDurationMinutes: 300, resetsAt: Date().addingTimeInterval(3600))]),
            QuotaBucket(id: "fixture-b", name: "Additional quota", windows: [QuotaWindow(id: "secondary", usedPercentage: 60, windowDurationMinutes: 10080, resetsAt: Date().addingTimeInterval(86000))])
        ], source), dailyTokens: .available([DailyTokenUsage(day: "2026-09-10", tokens: 1000)], source))
    }
}
#endif
