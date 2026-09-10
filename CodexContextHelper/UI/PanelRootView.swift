import SwiftUI

struct PanelRootView: View {
    @ObservedObject var model: PanelViewModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.showsSettings {
                SettingsView(model: model)
            } else if model.showsAgents {
                AgentsPageView(model: model)
                Divider()
                CompactAccountUsageView(model: model).padding(12).layoutPriority(1)
            } else if model.showsHistory {
                DailyHistoryView(model: model)
                Divider()
                CompactAccountUsageView(model: model).padding(12).layoutPriority(1)
            } else if let task = model.detailTask {
                ExactCounterDetailView(model: model, task: task)
            } else if model.detailID != nil {
                ContentUnavailableView("Task unavailable", systemImage: "questionmark.folder", description: Text("This task left the recent list. Use Back to choose another task."))
            } else {
                CompactContextView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colorScheme == .dark ? Color(red: 0.175, green: 0.175, blue: 0.17) : Color(red: 0.96, green: 0.96, blue: 0.95))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .onExitCommand(perform: model.back)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.showsSettings || model.detailID != nil || model.showsAgents || model.showsHistory {
                Button(action: model.back) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back to dashboard")
                    .accessibilityIdentifier("panel.back")
                    .help("Back (Escape)")
            }
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.system(.subheadline, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: model.openSettings) { Image(systemName: "gearshape") }
                .accessibilityLabel("Open settings").accessibilityIdentifier("panel.settings").help("Settings")
            Button(action: model.openHistory) { Image(systemName: "chart.bar.xaxis") }
                .accessibilityLabel("Daily token history").accessibilityIdentifier("panel.history").help("Daily token history")
            Button(action: model.hide) { Image(systemName: "minus") }
                .accessibilityLabel("Hide panel").accessibilityIdentifier("panel.hide").help("Hide panel; restore from the menu bar")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
    private var headerTitle: String {
        if model.showsSettings { return "Settings" }
        if model.showsAgents { return "Agents" }
        if model.showsHistory { return "Daily history" }
        if model.detailID != nil { return "Task detail" }
        return "Codex Context Helper"
    }
}
