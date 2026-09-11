import SwiftUI

struct ExactCounterDetailView: View {
    @ObservedObject var model: PanelViewModel
    let task: TaskSnapshot
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.task.title).font(.title3).fontWeight(.semibold).textSelection(.enabled)
                    Text("\(task.task.model ?? "Model unavailable") · \(task.task.activity.rawValue.capitalized)")
                        .font(.callout).foregroundStyle(.secondary)
                    if task.id == model.selection.threadID {
                        ProvenanceBadge(text: model.selection.provenance.label, symbol: "scope")
                    }
                }
                context
                if task.cost.value != nil { cost }
                else {
                    MonitorCard(title: "Cost & credits") {
                        Text("Codex isn’t reporting a cost or credit total for this task. A value will appear here if it becomes available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
        }
        .accessibilityIdentifier("task.detail")
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonitorCard(title: "Current context") {
                if let snapshot = task.context.value {
                    MetricLine(label: "Estimated remaining", value: "\(snapshot.estimatedRemainingPercentage)%")
                    Text("Uses a source-derived calculation: the latest saved context total, a 12,000-token baseline, and whole-percent rounding. This estimates user-controllable context; it is not an exact measure of every token in memory. Codex versions may change this calculation; matching saved fields does not establish live parity.")
                        .font(.caption).foregroundStyle(.secondary)
                    MetricLine(label: "Reported model window", value: snapshot.modelContextWindow.formatted() + " tokens")
                } else {
                    Text(task.context.unavailableReason?.label ?? "Unavailable").foregroundStyle(.secondary)
                }
                Text("Session log · \(model.freshness(task.context))").font(.caption).foregroundStyle(.secondary)
                if let versions = task.context.provenance?.producerVersions, !versions.isEmpty {
                    Text("Recorded by Codex \(versions.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                if let timestamp = task.context.provenance?.counterAt {
                    Text("Last saved response: \(timestamp.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot = task.context.value {
                MonitorCard(title: "Most recent response · exact tokens") {
                    TokenCountersView(counters: snapshot.latestResponse)
                }
                MonitorCard(title: "Cumulative task activity · exact tokens") {
                    TokenCountersView(counters: snapshot.cumulative)
                    Text("Cumulative activity is a running task total, not current context occupancy. Cached input is included in input; reasoning is included in output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cost: some View {
        MonitorCard(title: "Task-only backend estimates") {
            MetricLine(label: "Estimated credits", value: model.creditsLabel(task.cost))
            if let usd = task.cost.value?.estimatedUSD { MetricLine(label: "Estimated USD", value: "$" + model.decimal(usd)) }
            Text("Codex-provided estimates · \(model.freshness(task.cost))")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = task.cost.unavailableReason {
                Text(issue.label).font(.caption).foregroundStyle(.secondary)
            }
            Text("USD is shown only when returned by Codex. No local token pricing or credit-to-dollar conversion is applied.")
                .font(.caption).foregroundStyle(.secondary)
            if let estimate = task.cost.value, !estimate.groups.isEmpty {
                DisclosureGroup("Model and token groups · \(estimate.groups.count)") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(estimate.groups.enumerated()), id: \.offset) { _, group in
                            costGroup(group)
                        }
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }
    }

    private func costGroup(_ group: TaskCostGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.model ?? "Model unavailable").font(.subheadline).fontWeight(.semibold)
            MetricLine(label: "Reasoning effort", value: group.reasoningEffort ?? "Unavailable")
            MetricLine(label: "Speed", value: group.speed ?? "Unavailable")
            MetricLine(label: "Token type", value: group.tokenType ?? "Unavailable")
            MetricLine(label: "Tokens", value: tokenValue(group.tokens))
            MetricLine(label: "Input", value: tokenValue(group.inputTokens))
            MetricLine(label: "Cached input (within input)", value: tokenValue(group.cachedInputTokens))
            MetricLine(label: "Net new input", value: tokenValue(group.netNewInputTokens))
            MetricLine(label: "Output", value: tokenValue(group.outputTokens))
            MetricLine(label: "Total", value: tokenValue(group.totalTokens))
            MetricLine(label: "Estimated credits", value: group.creditMicros.map { model.decimal(Decimal($0) / 1_000_000) } ?? "Unavailable")
            MetricLine(label: "Estimated USD", value: group.usdMicros.map { "$" + model.decimal(Decimal($0) / 1_000_000) } ?? "Unavailable")
        }
    }
    private func tokenValue(_ value: Int64?) -> String { value?.formatted() ?? "Unavailable" }
}

private struct TokenCountersView: View {
    let counters: TokenCounters
    var body: some View {
        VStack(spacing: 7) {
            MetricLine(label: "Input", value: counters.input.formatted())
            MetricLine(label: "Cached input (within input)", value: counters.cachedInput.formatted())
            MetricLine(label: "Output", value: counters.output.formatted())
            MetricLine(label: "Reasoning (within output)", value: counters.reasoningOutput.formatted())
            Divider()
            MetricLine(label: "Total", value: counters.total.formatted()).fontWeight(.semibold)
        }
    }
}
