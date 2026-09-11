import Foundation

actor ContextSnapshotRepository {
    nonisolated let root: URL
    private let watcher: SessionDirectoryWatcher
    private var tasks: [String: TaskSummary] = [:]
    private var readers: [String: SessionLogReader] = [:]

    init(root: URL = CodexDataLocation.sessions) {
        self.root = root
        watcher = SessionDirectoryWatcher(root: root)
    }
    func configure(tasks recent: [TaskSummary], onChange: @escaping @Sendable (Set<String>) -> Void) {
        let selected = Array(recent.prefix(10))
        let next = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in Array(readers.keys) where next[id]?.sessionPath != tasks[id]?.sessionPath || next[id] == nil {
            readers.removeValue(forKey: id)
        }
        tasks = next
        watcher.update(paths: next.compactMapValues(\.sessionPath), onChange: onChange)
    }
    func refresh(ids: Set<String>? = nil) -> [String: SessionReadResult] {
        var results: [String: SessionReadResult] = [:]
        for task in tasks.values where ids == nil || ids!.contains(task.id) {
            guard let path = task.sessionPath else {
                results[task.id] = SessionReadResult(context: .unavailable(.missingSession), moreData: false); continue
            }
            do {
                if readers[task.id] == nil { readers[task.id] = try SessionLogReader(root: root, path: path, threadID: task.id) }
                let result = readers[task.id]!.refresh()
                results[task.id] = result
                if result.context.unavailableReason == .missingSession { readers.removeValue(forKey: task.id) }
            } catch { results[task.id] = SessionReadResult(context: .unavailable(.missingSession), moreData: false) }
        }
        return results
    }
    /// Descendant snapshots use a temporary descriptor, never an unbounded set of persistent watchers.
    func readDescendant(_ task: TaskSummary) async -> SessionReadResult {
        guard let path = task.sessionPath, let reader = try? SessionLogReader(root: root, path: path, threadID: task.id) else {
            return SessionReadResult(context: .unavailable(.missingSession), moreData: false)
        }
        // Retain this one reader across bounded slices so a large descendant log can finish.
        // Cancellation releases its descriptor; no descendant becomes a persistent watcher.
        for _ in 0..<32 {
            let result = reader.refresh()
            if !result.moreData || Task.isCancelled { return result }
            await Task.yield()
        }
        return SessionReadResult(context: .unavailable(.unsupportedSchema), moreData: false)
    }
    func stop() { readers.removeAll(); tasks.removeAll(); watcher.stop() }
    var watchedTaskCount: Int { tasks.count }
}
