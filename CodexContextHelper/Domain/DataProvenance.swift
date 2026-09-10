import Foundation

enum MeasurementKind: String, Codable, Sendable { case exact, backendEstimated }
enum DataSource: String, Codable, Sendable { case sessionLog, appServer, derived }

struct DataProvenance: Equatable, Codable, Sendable {
    var source: DataSource
    var schemaVersion: String
    var observedAt: Date
    var counterAt: Date?
    var measurement: MeasurementKind
    var invalidated: Bool = false

    init(source: DataSource, schemaVersion: String, observedAt: Date = Date(), counterAt: Date? = nil, measurement: MeasurementKind = .exact) {
        self.source = source
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.counterAt = counterAt
        self.measurement = measurement
    }

    func isStale(at now: Date = Date(), maxAge: TimeInterval = 60) -> Bool {
        invalidated || now.timeIntervalSince(observedAt) > maxAge
    }
}

enum UnavailableReason: String, Codable, Sendable {
    case connecting, noData, signedOut, permissionDenied, unsupportedSchema
    case invalidCounters, missingSession, disconnected, ambiguousSelection
    case unapprovedExecutable, executableChanged, unsupportedInclusiveCost
    case updatingContext

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .noData: "Unavailable"
        case .signedOut: "Signed out"
        case .permissionDenied: "Accessibility permission unavailable"
        case .unsupportedSchema: "Unsupported data format"
        case .invalidCounters: "Unsupported counters"
        case .missingSession: "Session log unavailable"
        case .disconnected: "Disconnected"
        case .ambiguousSelection: "Selection is ambiguous"
        case .unapprovedExecutable: "Approve the Codex executable"
        case .executableChanged: "Codex executable changed"
        case .unsupportedInclusiveCost: "Inclusive cost unavailable"
        case .updatingContext: "Updating context…"
        }
    }
}

enum Metric<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value, DataProvenance)
    case unavailable(UnavailableReason)

    var value: Value? { if case .available(let value, _) = self { value } else { nil } }
    var provenance: DataProvenance? { if case .available(_, let provenance) = self { provenance } else { nil } }
    var unavailableReason: UnavailableReason? { if case .unavailable(let reason) = self { reason } else { nil } }
}

enum SelectionProvenance: Equatable, Sendable {
    case exact
    case pinned
    case latest
    case inferred(UnavailableReason)
    var label: String {
        switch self {
        case .exact: "Selected in Codex"
        case .pinned: "Pinned task"
        case .latest: "Latest activity"
        case .inferred: "Following recent activity"
        }
    }
}

struct TaskSelection: Equatable, Sendable {
    var threadID: String?
    var provenance: SelectionProvenance
}

extension Metric {
    func markedStale() -> Self {
        guard case .available(let value, var provenance) = self else { return self }
        provenance.invalidated = true
        return .available(value, provenance)
    }
}
