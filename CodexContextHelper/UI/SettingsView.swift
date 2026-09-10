import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonitorCard(title: "Local Codex connection") {
                    Text("Approve an installed Codex executable to read local task and account data.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Absolute executable path", text: $model.executableCandidate)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Codex executable path")
                        .accessibilityIdentifier("settings.executable")
                    HStack {
                        Button("Discover", action: model.discoverExecutable)
                        Button("Choose…", action: model.chooseExecutable)
                        Spacer()
                        Button(model.isApproving ? "Checking…" : "Approve", action: model.approveExecutable)
                            .disabled(model.isApproving || model.executableCandidate.isEmpty)
                            .accessibilityIdentifier("settings.approve")
                    }
                    if let approved = model.settings.approvedExecutable {
                        Label("Approved Codex \(approved.version)", systemImage: "checkmark.shield").font(.caption)
                    }
                    if let message = model.settingsMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.message")
                    }
                }
                MonitorCard(title: "Task selection") {
                    HStack {
                        Label(model.accessibilityGranted ? "Accessibility allowed" : "Accessibility not granted", systemImage: "accessibility")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    Text("Latest activity and pinned tasks work without Accessibility permission. You can manage the app’s existing permission here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility Settings", action: model.requestAccessibility)
                        .accessibilityIdentifier("settings.accessibility")
                }
                MonitorCard(title: "Panel preferences") {
                    Stepper(value: Binding(get: { model.settings.recentTaskCount }, set: { model.setRecentTaskCount($0) }), in: 1...10) {
                        Text("Recent tasks: \(model.settings.recentTaskCount)")
                    }.accessibilityIdentifier("settings.recentCount")
                    Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .accessibilityIdentifier("settings.launchAtLogin")
                    Text("Registration: \(model.loginStatus)").font(.caption).foregroundStyle(.secondary)
                }
                MonitorCard(title: "Data and privacy") {
                    Text("Reads local Codex state and its authenticated app-server. The monitor does not modify tasks or store raw prompts or tool outputs.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Exact session counters, cumulative token activity and backend cost estimates are separate measurements. Invoiced cost is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.occupancyVerified {
                        Text("Context remaining is estimated from the latest saved response. Raw token counts and calculation details are available in each task’s Details view.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
        }
    }
}
