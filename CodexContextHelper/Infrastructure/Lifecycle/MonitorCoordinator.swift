import AppKit

/// Owns the single backend and independent, bounded refresh lanes. All presentation writes stay on MainActor.
@MainActor
final class MonitorCoordinator {
    typealias BackendFactory = @Sendable (ApprovedExecutable) async throws -> any MonitorBackend
    private let model: PanelViewModel
    private let contexts: ContextSnapshotRepository
    private let desktopTitles: DesktopTaskTitleRepository
    private var localTitles: [String: String] = [:]
    private let localCatalog: LocalTaskCatalog
    private var localCatalogTask: Task<Void, Never>?
    private var localTasks: [String: TaskSummary] = [:]
    private var remoteTasks: [TaskSummary] = []
    private var conflictedIDs: Set<String> = []
    private var contextRevision = 0
    private var lineageRevision = 0
    private var nextLocalCatalog = Date.distantPast
    private var nextLocalLineage = Date.distantPast
    private var nextDescendantContext = Date.distantPast
    private var localGeneration = 0
    private var lineageContextTask: Task<Void, Never>?
    private var remoteLineage: ThreadLineage?
    private var remoteLineageRoot: String?
    private let usage = TaskUsageRepository()
    private let factory: BackendFactory
    private let evidence: @MainActor () async -> TaskSelectionEvidence
    private var backend: (any MonitorBackend)?
    private var loop: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var costTask: Task<Void, Never>?
    private var lineageTask: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var restartRequested = false
    private var backoff = ReconnectBackoff()
    private var nextConnect = Date.distantPast
    private var nextCatalog = Date.distantPast
    private var nextAccount = Date.distantPast
    private var nextCost = Date.distantPast
    private var nextSelection = Date.distantPast
    private var nextContext = Date.distantPast
    private var nextLineage = Date.distantPast
    private var lastEvidence: TaskSelectionEvidence?
    private var recentIDs: [String] = []
    private var selectionRevision = 0
    private var lineageRoot: String?
    private var lineage = ThreadLineage(tasks: [], exhaustive: false)
    private var descendantContexts: [String: Metric<ContextSnapshot>] = [:]
    private var costs: [String: Metric<TaskCostEstimate>] = [:]

    init(model: PanelViewModel, contexts: ContextSnapshotRepository = ContextSnapshotRepository(),
         desktopTitles: DesktopTaskTitleRepository? = nil,
         factory: @escaping BackendFactory = { try await LocalMonitorBackend(approved: $0) },
         evidence: (@MainActor () async -> TaskSelectionEvidence)? = nil) {
        self.model = model; self.contexts = contexts; self.factory = factory
        localCatalog = LocalTaskCatalog(root: contexts.root)
        self.desktopTitles = desktopTitles ?? DesktopTaskTitleRepository(databaseURL: contexts.root.deletingLastPathComponent().appendingPathComponent("sqlite/codex-dev.db"))
        let selectionLogs = DesktopSelectionRepository()
        self.evidence = evidence ?? {
            let process = DesktopAppInstance.current()
            let result = await selectionLogs.selection(for: process)
            return DesktopAppInstance.current() == process ? result : .unavailable(.disconnected)
        }
    }

    func start() {
        guard loop == nil else { return }
        stopped = false
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    func refresh() {
        nextLocalCatalog = .distantPast; nextLocalLineage = .distantPast; nextDescendantContext = .distantPast
        nextCatalog = .distantPast; nextAccount = .distantPast; nextCost = .distantPast
        nextSelection = .distantPast; nextContext = .distantPast; nextLineage = .distantPast
        lastEvidence = nil
    }
    func retryAccount() {
        nextConnect = .distantPast; backoff.reset()
        refresh()
    }
    func preferencesChanged() { refresh(); if !model.tracksAgents { clearLineage() } }
    func agentPageChanged() {
        if lineageRoot != model.agentRootTask?.id { clearLineage(); nextLineage = .distantPast }
    }
    func taskTrackingChanged() {
        selectionRevision += 1
        selectionTask?.cancel(); selectionTask = nil
        lastEvidence = nil; nextSelection = .distantPast; nextContext = .distantPast; nextCost = .distantPast
        agentPageChanged()
    }
    func executableApproved() {
        restartRequested = true; nextConnect = .distantPast; backoff.reset()
        model.connectionIssue = .connecting
    }

    func disconnectAccount() {
        generation += 1
        catalogTask?.cancel(); catalogTask = nil; accountTask?.cancel(); accountTask = nil
        costTask?.cancel(); costTask = nil; lineageTask?.cancel(); lineageTask = nil
        restartRequested = true; nextConnect = .distantPast
        model.account.quotas = model.account.quotas.markedStale()
        model.account.dailyTokens = model.account.dailyTokens.markedStale()
        model.connectionIssue = .unapprovedExecutable
        remoteTasks = []; remoteLineage = nil; remoteLineageRoot = nil
        costs = [:]
        model.tasks = model.tasks.map { var row = $0; row.cost = .unavailable(.noData); return row }
        mergeCatalog(); updateLocalLineage()
    }

    /// Local reads always run, including while the optional child is connecting or stopping.
    func poll(now: Date = Date()) async {
        guard !stopped else { return }
        if model.panelVisible { model.now = now }
        if now >= nextLocalCatalog { refreshLocalCatalog(now: now) }
        if now >= nextSelection { resolveSelection(backend, now: now) }
        if now >= nextContext { refreshContexts(now: now) }
        if now >= nextLocalLineage, model.tracksAgents {
            nextLocalLineage = now.addingTimeInterval(5)
            updateLocalLineage()
        }
        guard connecting == nil else { return }
        if let backend {
            let healthy = await backend.isConnected()
            if restartRequested || !healthy {
                guard restartRequested || now >= nextConnect else { return }
                guard await disconnect() else { nextConnect = now.addingTimeInterval(30); return }
                if restartRequested { nextConnect = .distantPast }
                restartRequested = false
            }
        }
        guard !stopped else { return }
        guard let backend else {
            guard now >= nextConnect, model.connectionIssue != .executableChanged else { return }
            connect(now: now); return
        }
        if now >= nextCatalog { refreshCatalog(backend, now: now) }
        if now >= nextAccount, model.panelVisible || nextAccount == .distantPast { refreshAccount(backend, now: now) }
        if now >= nextCost, model.panelVisible, model.connectionIssue != .signedOut { refreshCosts(backend, now: now) }
        if now >= nextLineage, model.tracksAgents { refreshLineage(backend, now: now) }
    }

    private func connect(now: Date) {
        guard connecting == nil, backend == nil else { return }
        guard let approved = model.settings.approvedExecutable else { model.connectionIssue = .unapprovedExecutable; return }
        restartRequested = false
        model.connectionIssue = .connecting
        let current = generation
        connecting = Task {
            defer { connecting = nil }
            do {
                let created = try await factory(approved)
                backend = created
                guard !stopped, current == generation, model.settings.approvedExecutable == approved else {
                    if await created.close() { backend = nil }
                    return
                }
                try await created.start()
                guard !stopped, current == generation, model.settings.approvedExecutable == approved else {
                    if await created.close() { backend = nil }
                    return
                }
                backoff.reset(); nextConnect = .distantPast; refresh()
                model.connectionIssue = nil
            } catch {
                if let backend, await backend.close() { self.backend = nil }
                guard !stopped, current == generation, model.settings.approvedExecutable == approved else { return }
                let executableError = error as? ExecutableError
                model.connectionIssue = executableError == nil ? .disconnected : .executableChanged
                nextConnect = Date().addingTimeInterval(backoff.failed())
            }
        }
    }

    @discardableResult
    private func disconnect() async -> Bool {
        generation += 1
        // Only remote operations are invalidated. Local readers retain their offsets and watchers.
        catalogTask?.cancel(); catalogTask = nil; accountTask?.cancel(); accountTask = nil
        costTask?.cancel(); costTask = nil; lineageTask?.cancel(); lineageTask = nil
        selectionRevision += 1; selectionTask?.cancel(); selectionTask = nil
        lastEvidence = nil; nextSelection = .distantPast
        await usage.invalidate()
        model.tasks = model.tasks.map { var row = $0; row.cost = row.cost.markedStale(); row.task.activity = .unknown; return row }
        model.account.quotas = model.account.quotas.markedStale()
        model.account.dailyTokens = model.account.dailyTokens.markedStale()
        costs = costs.mapValues { $0.markedStale() }
        remoteTasks = remoteTasks.map { var task = $0; task.activity = .unknown; return task }
        remoteLineage = nil; remoteLineageRoot = nil
        updateLocalLineage()
        model.connectionIssue = model.settings.approvedExecutable == nil ? .unapprovedExecutable : .disconnected
        guard let backend else { return true }
        guard await backend.close() else { return false }
        self.backend = nil
        nextConnect = Date().addingTimeInterval(backoff.failed())
        return true
    }
    func stop() async -> Bool {
        stopped = true; loop?.cancel(); loop = nil
        localGeneration += 1
        localCatalogTask?.cancel(); localCatalogTask = nil
        contextTask?.cancel(); contextTask = nil
        lineageContextTask?.cancel(); lineageContextTask = nil
        await connecting?.value
        let closed = await disconnect()
        await contexts.stop(); await localCatalog.stop()
        return closed
    }

    private func refreshLocalCatalog(now: Date) {
        guard localCatalogTask == nil else { return }
        nextLocalCatalog = now.addingTimeInterval(5)
        let current = localGeneration
        localCatalogTask = Task {
            defer { if current == localGeneration { localCatalogTask = nil } }
            let snapshot = await localCatalog.refresh()
            let titles = await desktopTitles.titles(for: snapshot.tasks.map(\.id))
            guard !stopped, current == localGeneration, !Task.isCancelled else { return }
            if conflictedIDs != snapshot.conflictedIDs {
                conflictedIDs = snapshot.conflictedIDs
                contextRevision += 1
                contextTask?.cancel(); contextTask = nil
                clearLineage()
            }
            localTitles = titles
            localTasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            model.localDiscoveryIssue = snapshot.issue
            mergeCatalog()
            updateLocalLineage()
            await configureWatchers()
            if snapshot.issue == .connecting { nextLocalCatalog = .distantPast }
        }
    }

    /// Local paths and counters remain authoritative; remote data only enriches matching identities.
    private func enriched(_ local: TaskSummary, with remote: TaskSummary) -> TaskSummary {
        var task = remote
        task.sessionPath = local.sessionPath ?? remote.sessionPath
        task.updatedAt = max(local.updatedAt, remote.updatedAt)
        task.recencyAt = max(local.recencyAt ?? local.updatedAt, remote.recencyAt ?? remote.updatedAt)
        if let title = localTitles[local.id] { task.title = title }
        else if remote.title == "Untitled task" { task.title = local.title }
        task.model = local.model ?? remote.model
        task.parentThreadID = local.parentThreadID ?? remote.parentThreadID
        task.agentName = local.agentName ?? remote.agentName
        return safeSessionPath(task)
    }

    private func safeSessionPath(_ task: TaskSummary) -> TaskSummary {
        guard conflictedIDs.contains(task.id) else { return task }
        var task = task; task.sessionPath = nil
        return task
    }

    private func mergeCatalog() {
        var catalog = localTasks.filter { $0.value.parentThreadID == nil }
        for remote in remoteTasks {
            catalog[remote.id] = localTasks[remote.id].map { enriched($0, with: remote) } ?? safeSessionPath(remote)
        }
        for (id, title) in localTitles where catalog[id] != nil { catalog[id]?.title = title }
        let recent = Array(catalog.values.sorted {
            let left = $0.recencyAt ?? $0.updatedAt, right = $1.recencyAt ?? $1.updatedAt
            return left == right ? $0.id < $1.id : left > right
        }.prefix(model.settings.recentTaskCount))
        recentIDs = recent.map(\.id)
        let previous = Dictionary(model.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.tasks = recent.map { task in
            var row = previous[task.id] ?? TaskSnapshot(task: task)
            var task = task
            task.model = task.model ?? row.task.model
            task.agentName = task.agentName ?? row.task.agentName
            row.task = task
            return row
        }
        if let selectedID = model.selection.threadID, !recentIDs.contains(selectedID), var selected = previous[selectedID] {
            if let local = localTasks[selectedID] { selected.task = enriched(local, with: selected.task) }
            model.tasks.append(selected)
        }
        for index in model.tasks.indices where conflictedIDs.contains(model.tasks[index].id) {
            model.tasks[index].task.sessionPath = nil
            model.tasks[index].context = .unavailable(.unsupportedSchema)
        }
        lastEvidence = nil; nextSelection = .distantPast
        selectionRevision += 1; selectionTask?.cancel(); selectionTask = nil
        resolveSelection(backend, now: Date())
    }

    private func refreshCatalog(_ backend: any MonitorBackend, now: Date) {
        guard catalogTask == nil else { return }
        nextCatalog = now.addingTimeInterval(5)
        let current = generation
        catalogTask = Task {
            defer { if current == generation { catalogTask = nil } }
            do {
                let tasks = try await backend.recentTasks(count: model.settings.recentTaskCount)
                guard current == generation, !Task.isCancelled else { return }
                let previous = Dictionary(remoteTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let activityChanged = Set(tasks.map(\.id)) != Set(previous.keys) || tasks.contains {
                    previous[$0.id]?.updatedAt != $0.updatedAt || previous[$0.id]?.activity != $0.activity
                }
                remoteTasks = tasks
                mergeCatalog()
                if case .pinned(let id) = model.trackingMode, !recentIDs.contains(id),
                   let pinned = try? await backend.selectedTask(id: id), pinned.id == id,
                   current == generation, model.trackingMode == .pinned(id), !Task.isCancelled,
                   let index = model.tasks.firstIndex(where: { $0.id == id }) {
                    model.tasks[index].task = localTasks[id].map { enriched($0, with: pinned) } ?? safeSessionPath(pinned)
                }
                guard current == generation, !Task.isCancelled else { return }
                lastEvidence = nil; nextSelection = .distantPast
                await configureWatchers()
                if activityChanged { nextCost = .distantPast }
            } catch {
                guard current == generation else { return }
                // Metadata is optional. Account reads and the local catalog keep working.
                remoteTasks = []; mergeCatalog()
            }
        }
    }
    private func refreshAccount(_ backend: any MonitorBackend, now: Date) {
        guard accountTask == nil else { return }
        nextAccount = now.addingTimeInterval(30)
        let current = generation
        accountTask = Task {
            defer { if current == generation { accountTask = nil } }
            let snapshot = await backend.accountUsage()
            guard current == generation, !Task.isCancelled else { return }
            // Signed-out status is explicit even when earlier estimates remain in the task cache.
            if snapshot.quotas.unavailableReason == .signedOut || snapshot.dailyTokens.unavailableReason == .signedOut {
                model.account = snapshot; model.connectionIssue = .signedOut
                model.tasks = model.tasks.map { var row = $0; row.cost = row.cost.markedStale(); return row }
                await usage.invalidate()
            } else {
                model.account.quotas = preservingFailed(snapshot.quotas, previous: model.account.quotas)
                model.account.dailyTokens = preservingFailed(snapshot.dailyTokens, previous: model.account.dailyTokens)
                model.connectionIssue = snapshot.quotas.value != nil || snapshot.dailyTokens.value != nil ? nil : snapshot.quotas.unavailableReason
            }
        }
    }
    private func preservingFailed<Value>(_ next: Metric<Value>, previous: Metric<Value>) -> Metric<Value> {
        next.value == nil && previous.value != nil ? previous.markedStale() : next
    }

    private func resolveSelection(_ backend: (any MonitorBackend)?, now: Date) {
        guard selectionTask == nil else { return }
        nextSelection = now.addingTimeInterval(1)
        let mode = model.trackingMode
        let revision = selectionRevision
        if mode != .codex {
            let oldID = model.selection.threadID
            if case .pinned(let id) = mode {
                let next = TaskSelection(threadID: id, provenance: .pinned)
                if model.selection != next { model.selection = next }
            }
            if oldID != model.selection.threadID {
                if !model.showsAgents { clearLineage(); nextLineage = .distantPast }
                nextCost = .distantPast
            }
            selectionTask = Task {
                await configureWatchers()
                if revision == selectionRevision { selectionTask = nil }
            }
            return
        }
        let current = generation
        selectionTask = Task {
            defer { if current == generation, revision == selectionRevision { selectionTask = nil } }
            let observed = await evidence()
            guard current == generation, revision == selectionRevision, model.trackingMode == mode, !Task.isCancelled else { return }
            guard observed != lastEvidence else { return }
            lastEvidence = observed
            var resolved: TaskSummary?
            var checked = observed
            if case .localTask(let id) = observed {
                if let local = localTasks[id], local.sessionPath != nil, !conflictedIDs.contains(id) {
                    resolved = enriched(local, with: model.tasks.first { $0.id == id }?.task ?? local)
                } else { checked = .unavailable(.missingSession) }
            }
            if case .selected(let ids, let titles) = observed {
                do {
                    if ids.count == 1, let id = ids.first {
                        if let local = localTasks[id] { resolved = enriched(local, with: model.tasks.first { $0.id == id }?.task ?? local) }
                        else if let backend {
                            let candidate = try await backend.selectedTask(id: id)
                            if candidate.id == id, titles.isEmpty || titles == [candidate.title] { resolved = candidate }
                        }
                    }
                } catch { checked = .unavailable(.disconnected) }
                if resolved == nil, case .selected = checked { checked = .unavailable(.ambiguousSelection) }
            }
            guard current == generation, revision == selectionRevision, model.trackingMode == mode, !Task.isCancelled else { return }
            let oldID = model.selection.threadID
            model.tasks.removeAll { !recentIDs.contains($0.id) && $0.id != resolved?.id }
            if let resolved {
                if let index = model.tasks.firstIndex(where: { $0.id == resolved.id }) { model.tasks[index].task = localTasks[resolved.id].map { enriched($0, with: resolved) } ?? safeSessionPath(resolved) }
                else { model.tasks.append(TaskSnapshot(task: safeSessionPath(resolved))) }
                model.selection = TaskSelection(threadID: resolved.id, provenance: .exact)
            } else {
                model.selection = TaskSelectionResolver.resolve(tasks: model.tasks.map(\.task), evidence: checked)
            }
            if oldID != model.selection.threadID {
                if !model.showsAgents { clearLineage(); nextLineage = .distantPast }
                nextCost = .distantPast
            }
            await configureWatchers()
        }
    }

    private func configureWatchers() async {
        var watched = model.recentTasks.map(\.task)
        if let selected = model.selectedTask?.task, !watched.contains(where: { $0.id == selected.id }) {
            if watched.count == 10 { watched.removeLast() }
            watched.append(selected)
        }
        let current = localGeneration
        await contexts.configure(tasks: watched) { [weak self] _ in
            Task { @MainActor in
                guard let self, current == self.localGeneration else { return }
                self.nextContext = .distantPast
                self.nextCost = min(self.nextCost, Date().addingTimeInterval(2))
                self.nextLineage = min(self.nextLineage, Date().addingTimeInterval(2))
                self.nextLocalLineage = min(self.nextLocalLineage, Date().addingTimeInterval(2))
                self.nextDescendantContext = min(self.nextDescendantContext, Date().addingTimeInterval(2))
                self.refreshContexts(now: Date())
            }
        }
        nextContext = .distantPast
    }
    private func refreshContexts(now: Date) {
        guard contextTask == nil else { return }
        nextContext = now.addingTimeInterval(5)
        let current = localGeneration, revision = contextRevision
        contextTask = Task {
            defer { if current == localGeneration, revision == contextRevision { contextTask = nil } }
            var pending: Set<String>?
            repeat {
                let results = await contexts.refresh(ids: pending)
                guard current == localGeneration, revision == contextRevision, !Task.isCancelled else { return }
                for (id, result) in results {
                    guard !conflictedIDs.contains(id), let index = model.tasks.firstIndex(where: { $0.id == id }) else { continue }
                    model.tasks[index].context = result.context
                    if let name = result.model { model.tasks[index].task.model = name }
                    model.tasks[index].task.agentName = result.agentName
                }
                updateRollup()
                pending = Set(results.filter { $0.value.moreData }.keys)
                if !pending!.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
            } while !pending!.isEmpty && !Task.isCancelled
        }
    }
    private func refreshCosts(_ backend: any MonitorBackend, now: Date) {
        guard costTask == nil else { return }
        nextCost = now.addingTimeInterval(30)
        let current = generation
        let ids = model.tasks.map(\.id) + (model.settings.includeSubagents ? lineage.tasks.map(\.id) : [])
        costTask = Task {
            defer { if current == generation { costTask = nil } }
            let values = await usage.refresh(ids: ids, using: backend) { [weak self] id, value in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    let displayed = self.model.connectionIssue == .signedOut ? value.markedStale() : value
                    self.costs[id] = displayed
                    if let index = self.model.tasks.firstIndex(where: { $0.id == id }) { self.model.tasks[index].cost = displayed }
                    self.updateRollup()
                }
            }
            guard current == generation, !Task.isCancelled else { return }
            costs = model.connectionIssue == .signedOut ? values.mapValues { $0.markedStale() } : values
            updateRollup()
        }
    }
    private func refreshLineage(_ backend: any MonitorBackend, now: Date) {
        guard lineageTask == nil, let root = model.agentRootTask else { return }
        nextLineage = now.addingTimeInterval(30)
        let current = generation, revision = lineageRevision
        lineageTask = Task {
            defer { if current == generation, revision == lineageRevision { lineageTask = nil } }
            let found = (try? await backend.descendants(rootID: root.id)) ?? ThreadLineage(tasks: [], exhaustive: false)
            guard current == generation, revision == lineageRevision, model.tracksAgents, model.agentRootTask?.id == root.id, !Task.isCancelled else { return }
            remoteLineage = found; remoteLineageRoot = root.id
            updateLocalLineage(); nextCost = .distantPast
        }
    }

    private func updateLocalLineage() {
        guard !stopped, model.tracksAgents, let root = model.agentRootTask else { return }
        var ids: Set<String> = [root.id]
        var changed = true
        while changed && ids.count <= 512 {
            changed = false
            for task in localTasks.values where !ids.contains(task.id) {
                if let parent = task.parentThreadID, ids.contains(parent) {
                    ids.insert(task.id); changed = true
                }
            }
        }
        var found = localTasks.filter { ids.contains($0.key) }
        found[root.id] = safeSessionPath(root)
        let remote = remoteLineageRoot == root.id ? remoteLineage : nil
        for task in remote?.tasks ?? [] {
            found[task.id] = localTasks[task.id].map { enriched($0, with: task) } ?? safeSessionPath(task)
        }
        // Locally discovered additional descendants mean the remote listing is not exhaustive either.
        let remoteIDs = Set(remote?.tasks.map(\.id) ?? [])
        let exhaustive = remote?.exhaustive == true && Set(found.keys).isSubset(of: remoteIDs)
        let previous = Dictionary(lineage.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if lineageRoot != root.id || Set(previous.keys) != Set(found.keys) { nextDescendantContext = .distantPast }
        lineageRoot = root.id
        let ordered = found.values.sorted { $0.id < $1.id }
        lineage = ThreadLineage(tasks: Array(ordered.prefix(200)).map { task in
            var task = task
            task.model = task.model ?? previous[task.id]?.model
            task.agentName = task.agentName ?? previous[task.id]?.agentName
            return task
        }, exhaustive: exhaustive && ordered.count <= 200)
        descendantContexts = descendantContexts.filter { found[$0.key] != nil }
        updateRollup()
        guard lineageContextTask == nil, Date() >= nextDescendantContext else { return }
        nextDescendantContext = Date().addingTimeInterval(30)
        let current = localGeneration, revision = lineageRevision
        // Use a snapshot; no remote request can hold up reading already discovered local descendants.
        let unwatched = lineage.tasks.filter { task in !model.tasks.contains { $0.id == task.id } }
        lineageContextTask = Task {
            defer { if current == localGeneration, revision == lineageRevision { lineageContextTask = nil } }
            for task in unwatched {
                guard !Task.isCancelled else { return }
                let result = await contexts.readDescendant(task)
                guard !stopped, current == localGeneration, revision == lineageRevision, model.tracksAgents, model.agentRootTask?.id == root.id, !Task.isCancelled else { return }
                descendantContexts[task.id] = conflictedIDs.contains(task.id) ? .unavailable(.unsupportedSchema) : result.context
                if let index = lineage.tasks.firstIndex(where: { $0.id == task.id }) {
                    lineage.tasks[index].model = result.model ?? task.model
                    lineage.tasks[index].agentName = result.agentName ?? task.agentName
                }
                updateRollup()
            }
        }
    }
    private func clearLineage() {
        lineageRevision += 1
        lineageTask?.cancel(); lineageTask = nil; lineageRoot = nil
        lineageContextTask?.cancel(); lineageContextTask = nil
        remoteLineage = nil; remoteLineageRoot = nil
        nextLocalLineage = .distantPast; nextDescendantContext = .distantPast
        lineage = ThreadLineage(tasks: [], exhaustive: false); descendantContexts = [:]; model.rollup = nil
        model.agentDiscovery = nil
    }
    private func updateRollup() {
        guard model.tracksAgents, let root = model.agentRootTask, lineageRoot == root.id else { model.rollup = nil; return }
        var values = descendantContexts
        for task in model.tasks { values[task.id] = task.context }
        let agentTasks = lineage.tasks.filter { $0.id != root.id }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }.map { task in
            var task = task
            if let watched = model.tasks.first(where: { $0.id == task.id }) {
                task.model = watched.task.model ?? task.model
                task.agentName = watched.task.agentName ?? task.agentName
            }
            return TaskSnapshot(task: task, context: values[task.id] ?? .unavailable(.noData), cost: costs[task.id] ?? .unavailable(.noData))
        }
        let discovery = AgentDiscoverySnapshot(rootID: root.id, tasks: agentTasks, exhaustive: lineage.exhaustive)
        if model.agentDiscovery != discovery { model.agentDiscovery = discovery }
        guard model.settings.includeSubagents else { model.rollup = nil; return }
        model.rollup = ThreadLineageResolver.rollup(root: root, lineage: lineage, contexts: values, costs: costs,
                                                  costIsThreadLocal: ThreadLineageResolver.costIsThreadLocal)
    }
}
