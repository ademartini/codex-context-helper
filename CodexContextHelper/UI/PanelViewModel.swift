import AppKit
import Combine

enum TaskTrackingMode: Equatable {
    case latest, codex, pinned(String)
}

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var settings: MonitorSettings
    @Published var tasks: [TaskSnapshot] = []
    @Published var selection = TaskSelection(threadID: nil, provenance: .inferred(.connecting))
    @Published var account = AccountUsageSnapshot(quotas: .unavailable(.connecting), dailyTokens: .unavailable(.connecting))
    @Published var connectionIssue: UnavailableReason? = .connecting
    @Published var detailID: String?
    @Published var showsSettings = false
    @Published var showsHistory = false
    @Published var trackingMode: TaskTrackingMode = .latest
    @Published var panelVisible = true
    @Published var executableCandidate = ""
    @Published var isApproving = false
    @Published var settingsMessage: String?
    @Published var rollup: AgentRollup?
    @Published var agentDiscovery: AgentDiscoverySnapshot?
    @Published var agentPageTask: TaskSummary?
    @Published var now = Date()
    @Published var loginStatus = "Off"
    let permission = AccessibilityPermissionController()
    private let settingsStore: any SettingsStoring
    var onPreferencesChanged: (() -> Void)?
    var onDataPreferencesChanged: (() -> Void)?
    var onAgentNavigation: (() -> Void)?
    var onTaskTrackingChange: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    var onExecutableApproved: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onLoginChange: ((Bool) -> Void)?

    init(settingsStore: any SettingsStoring = SettingsStore()) {
        self.settingsStore = settingsStore
        settings = settingsStore.load()
        executableCandidate = settings.approvedExecutable?.path ?? ""
        if settings.approvedExecutable == nil { connectionIssue = .unapprovedExecutable }
    }
    var selectedTask: TaskSnapshot? { tasks.first { $0.id == selection.threadID } }
    var detailTask: TaskSnapshot? { tasks.first { $0.id == detailID } }
    var recentTasks: [TaskSnapshot] { Array(tasks.prefix(settings.recentTaskCount)) }
    var weekToDate: WeekToDateUsage? {
        account.dailyTokens.value.map { WeekToDateUsage.calculate(days: $0, now: now) }
    }
    var showsAgents: Bool { agentPageTask != nil }
    var agentRootTask: TaskSummary? { agentPageTask ?? selectedTask?.task }
    var tracksAgents: Bool { panelVisible || showsAgents }
    var accessibilityGranted: Bool { permission.isGranted }
    var occupancyVerified: Bool { SessionLogSchema.occupancyVerified }

    func persist() { settings.normalize(); settingsStore.save(settings) }
    func setRecentTaskCount(_ count: Int) { settings.recentTaskCount = count; persist(); onPreferencesChanged?(); onDataPreferencesChanged?() }
    func track(_ mode: TaskTrackingMode) {
        if case .pinned(let id) = mode, !tasks.contains(where: { $0.id == id }) { return }
        trackingMode = mode
        if case .pinned(let id) = mode { selection = TaskSelection(threadID: id, provenance: .pinned) }
        if mode == .latest { selectLatest() }
        back(); onTaskTrackingChange?()
    }
    func selectLatest() {
        let latest = tasks.max {
            let lhs = $0.task.recencyAt ?? $0.task.updatedAt
            let rhs = $1.task.recencyAt ?? $1.task.updatedAt
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        let next = TaskSelection(threadID: latest?.id, provenance: .latest)
        if selection != next { selection = next }
    }
    var trackingLabel: String {
        switch trackingMode {
        case .latest: "Following latest activity"
        case .codex: selection.provenance == .exact ? "Following Codex selection" : "Following recent activity · no Codex match"
        case .pinned: "Pinned to this task"
        }
    }
    func openHistory() { back(); showsHistory = true; onPreferencesChanged?() }
    func setIncludeSubagents(_ enabled: Bool) { settings.includeSubagents = enabled; persist(); onPreferencesChanged?(); onDataPreferencesChanged?() }
    func openAgents() {
        agentPageTask = selectedTask?.task
        onPreferencesChanged?(); onAgentNavigation?()
    }
    func openDetail(_ id: String) {
        back(); detailID = id; onPreferencesChanged?()
    }
    func openSettings() {
        back(); showsSettings = true; onPreferencesChanged?()
        if executableCandidate.isEmpty { discoverExecutable() }
    }
    func back() {
        let wasAgents = showsAgents
        detailID = nil; showsSettings = false; showsHistory = false; agentPageTask = nil; onPreferencesChanged?()
        if wasAgents { onAgentNavigation?() }
    }
    func hide() { panelVisible = false; onVisibilityChanged?() }
    func show() { panelVisible = true; onVisibilityChanged?(); onRefresh?() }
    func refresh() { onRefresh?() }
    func requestAccessibility() { permission.requestFromSettings(); objectWillChange.send() }
    func setLaunchAtLogin(_ enabled: Bool) { onLoginChange?(enabled) }
    func chooseExecutable() {
        let picker = NSOpenPanel()
        picker.title = "Choose the installed native Codex executable"
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { executableCandidate = url.path }
    }
    func discoverExecutable() { Task { executableCandidate = await AppServerProcess.discover() ?? "" } }
    func approveExecutable() {
        guard !isApproving, !executableCandidate.isEmpty else { return }
        isApproving = true; settingsMessage = nil
        let candidate = executableCandidate
        Task {
            defer { isApproving = false }
            do {
                settings.approvedExecutable = try await AppServerProcess.approve(path: candidate)
                executableCandidate = settings.approvedExecutable!.path
                persist(); settingsMessage = "Approved Codex \(AppServerProcess.supportedVersion)."
                onExecutableApproved?()
            } catch {
                settingsMessage = "Approval failed. Choose a non-writable native Codex \(AppServerProcess.supportedVersion) executable. Nothing was installed."
            }
        }
    }
    func openCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func contextLabel(_ task: TaskSnapshot) -> String {
        guard let context = task.context.value else { return task.context.unavailableReason?.label ?? "Unavailable" }
        return "\(context.estimatedRemainingPercentage)% remaining"
    }
    func creditsLabel(_ metric: Metric<TaskCostEstimate>) -> String {
        guard let estimate = metric.value else { return "Unavailable" }
        return decimal(estimate.credits) + " credits"
    }
    func decimal(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    func staleNotice<Value>(_ metric: Metric<Value>) -> String? {
        guard let source = metric.provenance, source.isStale(at: now) else { return nil }
        return "Stale · last checked \(source.observedAt.formatted(date: .omitted, time: .shortened))"
    }
    func freshness<Value>(_ metric: Metric<Value>) -> String {
        guard let source = metric.provenance else { return metric.unavailableReason?.label ?? "Unavailable" }
        let age = max(0, Int(now.timeIntervalSince(source.observedAt)))
        return (source.isStale(at: now) ? "Stale · " : "Checked · ") + (age < 60 ? "\(age)s ago" : "\(age / 60)m ago")
    }
    func recordPosition(_ point: NSPoint) { settings.panelPosition = PanelPosition(x: point.x, y: point.y); persist() }
}
