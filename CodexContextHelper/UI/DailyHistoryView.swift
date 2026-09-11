import SwiftUI
import Charts

struct DailyHistoryView: View {
    @ObservedObject var model: PanelViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Account token activity").font(.headline)
                if let week = model.weekToDate, week.includedDays > 0 {
                    Text("\(week.tokens.formatted(.number.notation(.compactName))) this week")
                        .font(.title2).fontWeight(.semibold).monospacedDigit()
                    Text(week.isComplete ? "Monday through today" : "\(week.includedDays) of \(week.expectedDays) days reported")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let notice = model.staleNotice(model.account.dailyTokens) {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                if let days = model.account.dailyTokens.value, !days.isEmpty {
                    let chronological = days.sorted { $0.day < $1.day }
                    Chart(Array(chronological.suffix(7))) { day in
                        BarMark(x: .value("Day", String(day.day.suffix(5))), y: .value("Tokens", day.tokens))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis(.hidden).frame(height: 90)
                    .accessibilityLabel("Token activity for the last seven reported days")
                    Text("All reported days").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(chronological.reversed())) { day in
                        HStack {
                            Text(day.day)
                            Spacer()
                            Text(day.tokens.formatted()).monospacedDigit()
                        }.font(.caption)
                    }
                } else {
                    Text(model.connectionIssue == .unapprovedExecutable ? "Connect the Codex CLI in Settings to see account-wide history." : "Codex has not reported daily activity.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Account-wide tokens across responses. Local session totals are not used to fill missing history.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(minHeight: 0).accessibilityIdentifier("history.page")
    }
}
