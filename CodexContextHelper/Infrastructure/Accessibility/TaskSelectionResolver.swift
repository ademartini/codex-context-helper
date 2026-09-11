import Foundation

enum TaskSelectionEvidence: Equatable, Sendable {
    /// Desktop view metadata requires a verified local session, never a backend-only match.
    case localTask(String)
    case selected(ids: Set<String>, titles: Set<String>)
    case unavailable(UnavailableReason)
}

enum TaskSelectionResolver {
    static func resolve(tasks: [TaskSummary], evidence: TaskSelectionEvidence) -> TaskSelection {
        switch evidence {
        case .localTask(let id):
            let exists = tasks.contains { $0.id == id }
            return TaskSelection(threadID: exists ? id : nil, provenance: exists ? .exact : .inferred(.missingSession))
        case .unavailable(let reason): return TaskSelection(threadID: nil, provenance: .inferred(reason))
        case .selected(let ids, let titles):
            let knownIDs = Set(tasks.map(\.id))
            if ids.count == 1, let id = ids.first, knownIDs.contains(id) {
                let conflictingTitles = tasks.filter { titles.contains($0.title) && $0.id != id }
                if conflictingTitles.isEmpty { return TaskSelection(threadID: id, provenance: .exact) }
            }
            return TaskSelection(threadID: nil, provenance: .inferred(.ambiguousSelection))
        }
    }
}
