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

struct MonitorRecoveryView: View {
    @ObservedObject var model: PanelViewModel
    var expanded = false
    var body: some View {
        if let issue = model.connectionIssue {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if issue == .connecting { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "exclamationmark.circle") }
                    Text(issue.label).font(.caption).fontWeight(.medium)
                    Spacer(minLength: 0)
                    if issue == .signedOut {
                        Button("Open Codex", action: model.openCodex)
                    } else if issue != .connecting {
                        Button("Settings", action: model.openSettings)
                    }
                }
                if expanded {
                    Text(explanation(issue)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("panel.state")
        } else if expanded, case .inferred = model.selection.provenance {
            Text(model.accessibilityGranted ? "Following recent activity; Codex has not exposed a unique selected task." : "Following recent activity. Enable Accessibility in Settings to help identify the selected task.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func explanation(_ issue: UnavailableReason) -> String {
        switch issue {
        case .signedOut: "Sign in to the local Codex app to restore account data."
        case .unapprovedExecutable, .executableChanged: "Choose and approve the installed Codex executable in Settings."
        case .permissionDenied: "Accessibility is optional. Recent activity remains available as the selection fallback."
        case .connecting: "Waiting for the local Codex app-server."
        case .disconnected: "The local connection was interrupted. Cached values retain their last check time while the monitor reconnects."
        case .unsupportedSchema, .invalidCounters: "This data does not match the supported format. Values remain unavailable until a compatible source is available."
        default: "Available data remains visible. Check Settings for recovery options."
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
