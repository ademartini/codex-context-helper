import Foundation

enum AccessibilityEvidence: Equatable, Sendable {
    case selected(ids: Set<String>, titles: Set<String>)
    case unavailable(UnavailableReason)
}

enum TaskSelectionResolver {
    static func resolve(tasks: [TaskSummary], evidence: AccessibilityEvidence) -> TaskSelection {
        let fallback = tasks.max {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt
        }?.id
        switch evidence {
        case .unavailable(let reason): return TaskSelection(threadID: fallback, provenance: .inferred(reason))
        case .selected(let ids, let titles):
            let knownIDs = Set(tasks.map(\.id))
            if ids.count == 1, let id = ids.first, knownIDs.contains(id) {
                let conflictingTitles = tasks.filter { titles.contains($0.title) && $0.id != id }
                if conflictingTitles.isEmpty { return TaskSelection(threadID: id, provenance: .exact) }
            }
            if ids.isEmpty {
                let matches = tasks.filter { titles.contains($0.title) }
                if matches.count == 1 { return TaskSelection(threadID: matches[0].id, provenance: .exact) }
            }
            return TaskSelection(threadID: fallback, provenance: .inferred(.ambiguousSelection))
        }
    }
}
