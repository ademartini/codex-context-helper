import AppKit
import Combine

enum TaskTrackingMode: Equatable {
    case codex, pinned(String)
}

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var settings: MonitorSettings
    @Published var tasks: [TaskSnapshot] = []
    @Published var selection = TaskSelection(threadID: nil, provenance: .inferred(.connecting))
    @Published var account = AccountUsageSnapshot(quotas: .unavailable(.connecting), dailyTokens: .unavailable(.connecting))
    @Published var localDiscoveryIssue: UnavailableReason? = .connecting
    @Published var connectionIssue: UnavailableReason? = .connecting
    @Published var detailID: String?
    @Published var showsSettings = false
    @Published var showsHistory = false
    @Published var trackingMode: TaskTrackingMode = .codex
    @Published var panelVisible = true
    @Published var executableCandidate = ""
    @Published var isApproving = false
    @Published var isDiscoveringExecutable = false
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
    var onDisconnectAccount: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRetryAccount: (() -> Void)?
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
        if mode == .codex { selection = TaskSelection(threadID: nil, provenance: .inferred(.connecting)) }
        back(); onTaskTrackingChange?()
    }
    var trackingLabel: String {
        switch trackingMode {
        case .codex: "Following Codex selection"
        case .pinned: "Pinned to this task"
        }
    }
    var selectionExplanation: String {
        switch selection.provenance {
        case .inferred(.permissionDenied): "The helper can’t read Codex’s task-selection information. Choose a task below to pin it."
        case .inferred(.connecting): "Checking which task is selected in Codex. You can also pin a task below."
        case .inferred(.disconnected): "Open Codex to follow its selected task, or pin a task below."
        case .inferred(.noData): "Click a local task in Codex’s main window, or choose a task below to pin it."
        case .inferred(.missingSession): "The selected task’s saved session is not available locally yet. Choose a task below to pin it."
        default: "Automatic selection is unavailable. Click a local task in Codex’s main window to retry, or choose a task below to pin it."
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
    }
    func openAccountSettings() {
        openSettings()
        if executableCandidate.isEmpty || connectionIssue == .executableChanged { discoverExecutable() }
    }
    func back() {
        let wasAgents = showsAgents
        detailID = nil; showsSettings = false; showsHistory = false; agentPageTask = nil; onPreferencesChanged?()
        if wasAgents { onAgentNavigation?() }
    }
    func hide() { panelVisible = false; onVisibilityChanged?() }
    func show() { panelVisible = true; onVisibilityChanged?(); onRefresh?() }
    func refresh() { onRefresh?() }
    func retryAccountUsage() { onRetryAccount?() }
    func requestAccessibility() { permission.requestFromSettings(); objectWillChange.send() }
    func setLaunchAtLogin(_ enabled: Bool) { onLoginChange?(enabled) }
    func chooseExecutable() {
        let picker = NSOpenPanel()
        picker.title = "Choose the installed native Codex executable"
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { executableCandidate = url.path }
    }
    func revealSessionFolder() {
        let folder = FileManager.default.fileExists(atPath: CodexDataLocation.sessions.path) ? CodexDataLocation.sessions : CodexDataLocation.home
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    func discoverExecutable() {
        guard !isDiscoveringExecutable, !isApproving else { return }
        isDiscoveringExecutable = true
        Task {
            defer { isDiscoveringExecutable = false }
            executableCandidate = await AppServerProcess.discover() ?? ""
            if executableCandidate.isEmpty { settingsMessage = "No Codex CLI found. Install and sign in to the CLI to connect account usage, or use Choose CLI installation." }
        }
    }
    func disconnectAccountUsage() {
        settings.approvedExecutable = nil
        persist()
        connectionIssue = .unapprovedExecutable
        account.quotas = account.quotas.markedStale()
        account.dailyTokens = account.dailyTokens.markedStale()
        settingsMessage = "Account usage disconnected. Local monitoring continues."
        onDisconnectAccount?()
    }
    var localEmptyTitle: String {
        switch localDiscoveryIssue {
        case .connecting: "Looking for local Codex activity…"
        case .permissionDenied: "Can’t read local Codex activity"
        case .unsupportedSchema, .invalidCounters: "Local activity format unavailable"
        case .noData, .missingSession, nil: "No local Codex activity yet"
        default: "Local Codex activity unavailable"
        }
    }
    var localEmptyExplanation: String {
        switch localDiscoveryIssue {
        case .connecting: "Reading saved sessions on this Mac."
        case .permissionDenied: "The helper can’t access the Codex session folder. Check its access in Finder, then retry."
        case .unsupportedSchema, .invalidCounters: "Saved sessions could not be read. A helper update may be needed."
        case .noData, .missingSession, nil: "Start a local task in Codex. Saved context will appear here automatically."
        default: "Check the Codex session folder, then retry."
        }
    }
    var accountConnectionLabel: String {
        switch connectionIssue {
        case .unapprovedExecutable: "Requires a signed-in Codex CLI"
        case .connecting: "Connecting account usage…"
        case .executableChanged: "Codex CLI updated · review to reconnect"
        case .signedOut: "Sign in to the Codex CLI, then retry"
        case .unsupportedSchema: "Account data isn’t supported by this connection"
        case .permissionDenied: "Account connection access unavailable"
        case nil: "Account usage connected"
        default: "Account usage disconnected"
        }
    }
    static func approvalFailureMessage(_ error: Error) -> String {
        switch error as? ExecutableError {
        case .invalidFile: "Can’t read this executable. Discover or choose your installed Codex CLI."
        case .unsafePermissions: "This executable has unsafe ownership or permissions. Choose a trusted installation that other users can’t modify."
        case .unsupportedExecutable: "Choose the native Codex executable. Discover can find it inside an installed CLI package."
        case .changed: "The executable changed during approval. Review the installation and try again."
        case .unsupportedVersion: "This executable didn’t return a recognized Codex CLI version. Choose a Codex CLI installation."
        case .timedOut: "The Codex CLI did not respond in time. Try again or choose another installation."
        case .launchFailed, nil: "Couldn’t run the Codex CLI. Check the installation, then try again."
        }
    }
    func approveExecutable() {
        guard !isApproving, !executableCandidate.isEmpty else { return }
        isApproving = true; settingsMessage = nil
        let candidate = executableCandidate
        Task {
            defer { isApproving = false }
            do {
                settings.approvedExecutable = try await AppServerProcess.approve(path: candidate)
                executableCandidate = settings.approvedExecutable!.path
                persist(); settingsMessage = "Approved Codex CLI \(settings.approvedExecutable!.version). Connecting account usage…"
                onExecutableApproved?()
            } catch {
                settingsMessage = Self.approvalFailureMessage(error)
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
