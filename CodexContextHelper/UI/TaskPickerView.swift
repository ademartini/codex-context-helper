import SwiftUI

struct TaskPickerView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        Menu {
            Button { model.track(.latest) } label: {
                Label("Follow latest activity", systemImage: model.trackingMode == .latest ? "checkmark" : "clock")
            }
            Divider()
            Text("Recent tasks · newest first")
            ForEach(model.recentTasks) { task in
                Button { model.track(.pinned(task.id)) } label: {
                    Label(summary(task), systemImage: model.trackingMode == .pinned(task.id) ? "checkmark" : "pin")
                }
            }
            if case .pinned(let id) = model.trackingMode,
               !model.recentTasks.contains(where: { $0.id == id }), let task = model.selectedTask {
                Divider()
                Text("Pinned task")
                Button(summary(task)) { model.track(.pinned(id)) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.selectedTask?.task.title ?? "Choose a task")
                    .font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel("Choose monitored task")
        .accessibilityIdentifier("task.picker")
        .help("Follow activity automatically, or pin a recent task for this launch.")
    }

    private func summary(_ task: TaskSnapshot) -> String {
        let title = task.task.title.count > 44 ? String(task.task.title.prefix(43)) + "…" : task.task.title
        let status = task.task.activity == .unknown ? "Updated \(task.task.updatedAt.formatted(date: .omitted, time: .shortened))" : task.task.activity.rawValue.capitalized
        let context = task.context.value.map { "\($0.estimatedRemainingPercentage)% left" } ?? "No context data"
        return "\(title) — \(status) · \(context)"
    }
}
