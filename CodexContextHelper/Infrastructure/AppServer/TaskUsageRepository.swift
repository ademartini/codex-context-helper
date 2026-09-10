import Foundation

protocol TaskCostProviding: Sendable {
    func taskCost(threadID: String) async -> Metric<TaskCostEstimate>
}
extension AppServerRepository: TaskCostProviding {}

actor TaskUsageRepository {
    private var generation: UInt64 = 0
    private var cache: [String: Metric<TaskCostEstimate>] = [:]

    /// Fixed concurrency and bounded metadata-only cache. Old refresh generations cannot publish.
    func refresh(ids requested: [String], using provider: any TaskCostProviding,
                 onUpdate: @escaping @Sendable (String, Metric<TaskCostEstimate>) -> Void = { _, _ in }) async -> [String: Metric<TaskCostEstimate>] {
        generation &+= 1
        let current = generation
        var seen = Set<String>()
        let ids = Array(requested.filter { seen.insert($0).inserted }.prefix(200))
        let retained = Set(ids)
        cache = cache.filter { retained.contains($0.key) }
        await withTaskGroup(of: (String, Metric<TaskCostEstimate>).self) { group in
            var iterator = ids.makeIterator()
            for _ in 0..<min(3, ids.count) {
                if let id = iterator.next() { group.addTask { (id, await provider.taskCost(threadID: id)) } }
            }
            while let (id, value) = await group.next() {
                guard current == generation, !Task.isCancelled else { group.cancelAll(); continue }
                let next: Metric<TaskCostEstimate>
                if let estimate = value.value, estimate.threadID == id { next = value }
                else if let previous = cache[id], previous.value != nil { next = previous.markedStale() }
                else { next = .unavailable(value.unavailableReason ?? .unsupportedSchema) }
                cache[id] = next
                onUpdate(id, next)
                if let id = iterator.next() { group.addTask { (id, await provider.taskCost(threadID: id)) } }
            }
        }
        return cache
    }
    func invalidate() { generation &+= 1; cache = cache.mapValues { $0.markedStale() } }
}
