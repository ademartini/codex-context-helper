import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MonitorCard(title: "Account limits & history") {
                    Text("Requires an installed, signed-in Codex CLI. Task monitoring works without this connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.executableCandidate.isEmpty && (model.settings.approvedExecutable == nil || model.connectionIssue == .executableChanged) {
                        Text(model.executableCandidate).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.accountConnectionLabel).font(.caption).foregroundStyle(.secondary)
                    if model.settings.approvedExecutable == nil || model.connectionIssue == .executableChanged {
                        if model.executableCandidate.isEmpty {
                            Button(model.isDiscoveringExecutable ? "Looking for Codex CLI…" : "Find Codex CLI", action: model.discoverExecutable)
                                .disabled(model.isDiscoveringExecutable)
                        } else {
                            Text("Approve only a CLI you trust; file checks do not verify its publisher.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(model.isApproving ? "Checking…" : "Approve & connect", action: model.approveExecutable)
                                .disabled(model.isApproving || model.isDiscoveringExecutable)
                                .accessibilityIdentifier("settings.approve")
                        }
                    }
                    if let approved = model.settings.approvedExecutable {
                        Label("Approved Codex CLI \(approved.version)", systemImage: "checkmark.shield").font(.caption)
                        VStack(alignment: .leading, spacing: 8) {
                            if model.connectionIssue != nil && model.connectionIssue != .executableChanged {
                                Button("Retry", action: model.retryAccountUsage).disabled(model.connectionIssue == .connecting)
                            }
                            Button("Disconnect", action: model.disconnectAccountUsage)
                                .accessibilityLabel("Disconnect account limits and history")
                                .disabled(model.isApproving)
                                .accessibilityIdentifier("settings.disconnectAccount")
                        }
                    }
                    DisclosureGroup("Choose CLI installation") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Absolute executable path", text: $model.executableCandidate)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Codex executable path")
                                .accessibilityIdentifier("settings.executable")
                            HStack {
                                Button("Discover", action: model.discoverExecutable)
                                Button("Choose…", action: model.chooseExecutable)
                            }
                            if model.settings.approvedExecutable != nil && model.connectionIssue != .executableChanged {
                                Button("Approve & connect", action: model.approveExecutable)
                                    .disabled(model.executableCandidate.isEmpty)
                            }
                            Text("Discovery uses your login shell. Choose a trusted CLI; updates require approval.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 6).disabled(model.isApproving || model.isDiscoveringExecutable)
                    }.accessibilityIdentifier("settings.advanced")
                    if let message = model.settingsMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.message")
                    }
                }
                MonitorCard(title: "Task selection") {
                    Text("Follows tasks you click in Codex’s main window. Background responses won’t switch tasks. Use the task picker to pin one.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("No Accessibility permission needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MonitorCard(title: "Panel") {
                    Stepper(value: Binding(get: { model.settings.recentTaskCount }, set: { model.setRecentTaskCount($0) }), in: 1...10) {
                        Text("Recent tasks: \(model.settings.recentTaskCount)")
                    }.accessibilityIdentifier("settings.recentCount")
                    Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .accessibilityIdentifier("settings.launchAtLogin")
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Privacy") {
                    Text("Reads local Codex files and connected account data. Does not modify tasks or save prompts. No helper analytics.")
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
    }
}
