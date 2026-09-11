import SwiftUI

struct CompactContextView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if let task = model.selectedTask {
                        TaskPickerView(model: model)
                        HStack {
                            if let name = task.task.model { Text(name).lineLimit(1) }
                            Spacer()
                            Button("Details") { model.openDetail(task.id) }
                                .buttonStyle(.plain).accessibilityIdentifier("task.details")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(model.trackingLabel).font(.caption2).foregroundStyle(.secondary)
                        context(task)
                        AgentSummaryButton(model: model)
                        if task.cost.value != nil {
                            Text("\(model.creditsLabel(task.cost)) · estimated").font(.caption).foregroundStyle(.secondary)
                            if let notice = model.staleNotice(task.cost) { Text(notice).font(.caption2).foregroundStyle(.orange) }
                        }
                    } else if !model.tasks.isEmpty {
                        Text("Choose a task to monitor").font(.headline)
                        Text(model.selectionExplanation).font(.callout).foregroundStyle(.secondary)
                        TaskPickerView(model: model)
                    } else {
                        LocalActivityEmptyView(model: model)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).id("task-heading")
            }.scrollIndicators(.hidden)
            Divider()
            CompactAccountUsageView(model: model)
        }.padding(12)
    }

    @ViewBuilder private func context(_ task: TaskSnapshot) -> some View {
        if let context = task.context.value {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(context.estimatedRemainingPercentage)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("context remaining · est.").font(.caption).foregroundStyle(.secondary)
                }
                .help("Estimated from Codex’s latest saved response. Open task details for the calculation and timestamp.")
                ProgressView(value: Double(context.estimatedRemainingPercentage), total: 100)
                    .accessibilityLabel("Estimated context remaining")
                Text("\(context.latestResponse.total.formatted()) / \(context.modelContextWindow.formatted()) tokens")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("Latest saved context total, including Codex’s baseline. This is separate from cumulative session usage.")
                if let notice = model.staleNotice(task.context) { Text(notice).font(.caption2).foregroundStyle(.orange) }
            }
        } else {
            Text("Context: \(task.context.unavailableReason?.label ?? "Unavailable")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AgentListView: View {
    @ObservedObject var model: PanelViewModel
    private var discovery: AgentDiscoverySnapshot? {
        guard let discovery = model.agentDiscovery, discovery.rootID == model.agentRootTask?.id else { return nil }
        return discovery
    }
    @ViewBuilder var body: some View {
        if let discovery {
            if discovery.tasks.isEmpty {
                Text(discovery.exhaustive ? "No agents found for this task." : "No agents found yet; discovery is incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(discovery.tasks.enumerated()), id: \.element.id) { index, agent in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(agent.task.agentName ?? (agent.task.title == "Untitled task" ? "Agent \(index + 1)" : agent.task.title))
                                    .lineLimit(1).help(agent.task.title)
                                Spacer(minLength: 4)
                                if agent.task.activity != .unknown { Text(agent.task.activity.rawValue.capitalized).foregroundStyle(.secondary) }
                            }
                            HStack {
                                if let name = agent.task.model { Text(name).lineLimit(1) }
                                Spacer(minLength: 4)
                                Text(agent.context.value == nil ? "Context unavailable" : model.contextLabel(agent)).monospacedDigit()
                                    .help(agent.context.unavailableReason?.label ?? "Estimated from this agent’s latest saved context.")
                            }.foregroundStyle(.secondary)
                            if let context = agent.context.value {
                                Text("\(context.latestResponse.total.formatted()) / \(context.modelContextWindow.formatted()) tokens").monospacedDigit().foregroundStyle(.secondary)
                            }
                            if let notice = model.staleNotice(agent.context) { Text(notice).foregroundStyle(.orange) }
                        }
                        .font(.caption2).padding(7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityElement(children: .combine)
                    }
                }
                if !discovery.exhaustive { Text("More agents may exist.").font(.caption2).foregroundStyle(.secondary) }
            }
        } else {
            Text("Loading agents…").font(.caption).foregroundStyle(.secondary)
        }
    }

}

struct CompactAccountUsageView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account limits").font(.system(.caption, weight: .semibold))
            AccountConnectionView(model: model)
            if let notice = model.staleNotice(model.account.quotas) { Text(notice).font(.caption2).foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 9) {
                    if let buckets = model.account.quotas.value, !buckets.isEmpty {
                        ForEach(buckets) { bucket in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bucket.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(bucket.name)
                                ForEach(bucket.windows) { window in
                                    HStack(spacing: 6) {
                                        Text(window.compactDuration).frame(width: 35, alignment: .leading)
                                        ProgressView(value: window.remainingPercentage, total: 100)
                                        Text("\(Int(window.remainingPercentage.rounded()))% left").monospacedDigit()
                                    }
                                    .font(.caption2)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(bucket.name), \(window.compactDuration), \(Int(window.remainingPercentage.rounded())) percent remaining")
                                    .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
                                }
                                ForEach(bucket.unavailableWindows, id: \.self) { Text("\($0): unavailable").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    } else if model.connectionIssue == nil {
                        Text(model.account.quotas.unavailableReason?.label ?? "No account limits returned")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AgentSummaryButton: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        Button(action: model.openAgents) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "person.2")
                    Text(discovery.map { $0.tasks.isEmpty && !$0.exhaustive ? "Agents · partial discovery" : "\($0.tasks.count) agents\($0.exhaustive ? "" : " found")" } ?? "Agents")
                    Spacer()
                    if let total = discovery?.totalTokens {
                        Text("\(total.formatted(.number.notation(.compactName))) tokens")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                }
                if let discovery, !discovery.tasks.isEmpty, !discovery.coverageNote.isEmpty {
                    Text(String(discovery.coverageNote.dropFirst(3)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.caption).accessibilityIdentifier("compact.agents")
        .help("View this task’s agents. Total tokens count all their model responses, not just current context.")
    }
    private var discovery: AgentDiscoverySnapshot? {
        guard let value = model.agentDiscovery, value.rootID == model.selection.threadID else { return nil }
        return value
    }
}

struct AgentsPageView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.agentPageTask?.title ?? "Task agents").font(.headline).lineLimit(2)
                if let discovery = model.agentDiscovery, discovery.rootID == model.agentPageTask?.id {
                    Text(discovery.tasks.isEmpty && !discovery.exhaustive ? "Agent discovery is incomplete" : "\(discovery.tasks.count) agents\(discovery.exhaustive ? "" : " found")").font(.caption).foregroundStyle(.secondary)
                    if let total = discovery.totalTokens {
                        Text("\(total.formatted(.number.notation(.compactName))) total tokens\(discovery.coverageNote)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                AgentListView(model: model)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .accessibilityIdentifier("agents.page")
    }
}
