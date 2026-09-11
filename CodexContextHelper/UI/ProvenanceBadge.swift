import SwiftUI

struct ProvenanceBadge: View {
    let text: String
    var symbol: String = "info.circle"
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct MonitorCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MetricLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct LocalActivityEmptyView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.localDiscoveryIssue == .connecting { ProgressView().controlSize(.small) }
            Text(model.localEmptyTitle).font(.headline)
            Text(model.localEmptyExplanation).font(.caption).foregroundStyle(.secondary)
            if model.localDiscoveryIssue != .connecting {
                HStack {
                    if model.localDiscoveryIssue == .permissionDenied {
                        Button("Open session folder", action: model.revealSessionFolder)
                            .accessibilityIdentifier("local.openFolder")
                    } else if model.localDiscoveryIssue == .noData || model.localDiscoveryIssue == nil {
                        Button("Open Codex", action: model.openCodex)
                    }
                    Button("Retry", action: model.refresh).accessibilityIdentifier("local.retry")
                }.controlSize(.small)
            }
        }.accessibilityIdentifier("panel.state")
    }
}

struct AccountConnectionView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        if let issue = model.connectionIssue {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.accountConnectionLabel).font(.caption2).foregroundStyle(.secondary)
                if issue == .unapprovedExecutable {
                    Button("Connect limits & history", action: model.openAccountSettings)
                        .accessibilityIdentifier("account.connect")
                } else if issue == .executableChanged {
                    Button("Review update", action: model.openAccountSettings)
                        .accessibilityIdentifier("account.reviewUpdate")
                } else if issue != .connecting {
                    HStack {
                        Button("Retry", action: model.retryAccountUsage).accessibilityIdentifier("account.retry")
                        Button("Settings", action: model.openAccountSettings)
                    }
                }
            }.controlSize(.small)
        }
    }
}

struct RollupSummaryView: View {
    @ObservedObject var model: PanelViewModel
    let rootID: String
    var compact = false
    var body: some View {
        if model.settings.includeSubagents {
            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                if let rollup = model.rollup, rollup.rootThreadID == rootID {
                    rollupLine("Cumulative tokens", value: rollup.tokens.metric.value.map { $0.total.formatted() } ?? "Unavailable", coverage: rollup.tokens.coverage, freshness: model.freshness(rollup.tokens.metric))
                    rollupLine("Estimated credits", value: rollup.creditMicros.metric.value.map { model.decimal(Decimal($0) / 1_000_000) } ?? "Unavailable", coverage: rollup.creditMicros.coverage, freshness: model.freshness(rollup.creditMicros.metric))
                    rollupLine("Estimated USD", value: rollup.usdMicros.metric.value.map { "$" + model.decimal(Decimal($0) / 1_000_000) } ?? "Unavailable", coverage: rollup.usdMicros.coverage, freshness: model.freshness(rollup.usdMicros.metric))
                    if !compact {
                        Text(rollup.tokens.coverage.lineageExhaustive ? "Lineage discovery exhausted the available catalog." : "Known tasks only; additional descendants may exist.")
                            .font(.caption).foregroundStyle(.secondary)
                        if rollup.creditMicros.metric.unavailableReason == .unsupportedInclusiveCost {
                            Text("Inclusive cost is unavailable until backend estimates are verified to exclude descendant usage. Task-only estimates remain separate.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Tokens: \(model.freshness(rollup.tokens.metric)) · Credits: \(model.freshness(rollup.creditMicros.metric)) · USD: \(model.freshness(rollup.usdMicros.metric))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Agent totals unavailable for this task.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func rollupLine(_ label: String, value: String, coverage: RollupCoverage, freshness: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            Text("\(coverage.label) · \(freshness)").foregroundStyle(.secondary)
        }
        .font(compact ? .caption2 : .caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Root and agents, \(label): \(value); \(coverage.label); \(freshness)")
    }
}
