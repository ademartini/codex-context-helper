import Foundation

struct TokenCounters: Equatable, Codable, Sendable {
    let input: Int64
    let cachedInput: Int64
    let output: Int64
    let reasoningOutput: Int64
    let total: Int64

    init?(input: Int64, cachedInput: Int64, output: Int64, reasoningOutput: Int64, total: Int64) {
        guard input >= 0, cachedInput >= 0, output >= 0, reasoningOutput >= 0,
              total >= 0, cachedInput <= input, reasoningOutput <= output else { return nil }
        self.input = input; self.cachedInput = cachedInput; self.output = output
        self.reasoningOutput = reasoningOutput; self.total = total
    }

    static let zero = TokenCounters(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0)!

    func adding(_ other: Self) -> Self? {
        let sums = [(input, other.input), (cachedInput, other.cachedInput), (output, other.output),
                    (reasoningOutput, other.reasoningOutput), (total, other.total)].map { $0.addingReportingOverflow($1) }
        guard sums.allSatisfy({ !$0.overflow }) else { return nil }
        return Self(input: sums[0].partialValue, cachedInput: sums[1].partialValue,
                    output: sums[2].partialValue, reasoningOutput: sums[3].partialValue, total: sums[4].partialValue)
    }
}

struct ContextSnapshot: Equatable, Sendable {
    let latestResponse: TokenCounters
    let cumulative: TokenCounters
    let modelContextWindow: Int64
    var measurement: MeasurementKind { .exact }

    init?(latestResponse: TokenCounters?, cumulative: TokenCounters?, modelContextWindow: Int64?) {
        guard let latestResponse, let cumulative, let modelContextWindow, modelContextWindow > 0 else { return nil }
        self.latestResponse = latestResponse; self.cumulative = cumulative
        self.modelContextWindow = modelContextWindow
    }

    var usedPercentage: Double { min(100, max(0, Double(latestResponse.total) / Double(modelContextWindow) * 100)) }
    var remainingPercentage: Double { 100 - usedPercentage }
    var remainingTokens: Int64 { max(0, modelContextWindow - min(modelContextWindow, latestResponse.total)) }

    /// Matches Codex 0.153.4 TokenUsage::percent_of_context_window_remaining.
    /// Codex estimates user-controllable context after reserving a 12,000-token baseline.
    /// Source: codex-rs/protocol/src/protocol.rs at tag rust-v0.153.4.
    var estimatedRemainingPercentage: Int {
        let baseline: Int64 = 12_000
        guard modelContextWindow > baseline else { return 0 }
        let effectiveWindow = modelContextWindow - baseline
        let used = max(0, latestResponse.total - baseline)
        let remaining = max(0, effectiveWindow - used)
        return Int(min(100, max(0, Double(remaining) / Double(effectiveWindow) * 100)).rounded())
    }
    var estimatedUsedPercentage: Int { 100 - estimatedRemainingPercentage }
}

struct QuotaWindow: Equatable, Sendable, Identifiable {
    var id: String
    var usedPercentage: Double
    var windowDurationMinutes: Int?
    var resetsAt: Date?
    var remainingPercentage: Double { min(100, max(0, 100 - usedPercentage)) }
    var compactDuration: String {
        guard let minutes = windowDurationMinutes else { return "Limit" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct QuotaBucket: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var windows: [QuotaWindow]
    var unavailableWindows: [String] = []
}

struct DailyTokenUsage: Equatable, Sendable, Identifiable {
    /// Server-provided calendar day, normalized as YYYY-MM-DD; never infer a day for absent buckets.
    var day: String
    var tokens: Int64
    var id: String { day }
}

struct WeekToDateUsage: Equatable, Sendable {
    var tokens: Int64
    var includedDays: Int
    var expectedDays: Int
    var isComplete: Bool { includedDays == expectedDays && expectedDays > 0 }

    static func calculate(days: [DailyTokenUsage], now: Date, calendar inputCalendar: Calendar = .current) -> Self {
        // Server day keys use Gregorian dates even when the user prefers another calendar.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let distance = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -distance, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let deduplicated = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
        var tokens: Int64 = 0
        var included = 0
        for offset in 0...distance {
            let key = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start)!)
            if let day = deduplicated[key], day.tokens >= 0 {
                let sum = tokens.addingReportingOverflow(day.tokens)
                guard !sum.overflow else { continue }
                tokens = sum.partialValue; included += 1
            }
        }
        return Self(tokens: tokens, includedDays: included, expectedDays: distance + 1)
    }
}

struct AccountUsageSnapshot: Equatable, Sendable {
    var quotas: Metric<[QuotaBucket]>
    var dailyTokens: Metric<[DailyTokenUsage]>
}
