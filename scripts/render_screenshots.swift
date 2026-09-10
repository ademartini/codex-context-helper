// Render the actual SwiftUI views with synthetic data only; no live coordinator.
// Compile using scripts/render_screenshots.sh. Never reads Codex or app preferences.
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
private final class DemoSettings: SettingsStoring {
    func load() -> MonitorSettings { MonitorSettings() }
    func save(_ settings: MonitorSettings) {}
}

@main
struct ScreenshotRenderer {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide an output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let model = PanelViewModel(settingsStore: DemoSettings())
        let now = ISO8601DateFormatter().date(from: "2026-09-10T16:00:00Z")!
        model.now = now
        let source = DataProvenance(source: .sessionLog, schemaVersion: "synthetic-demo", observedAt: now, counterAt: now)
        func snapshot(_ id: String, _ title: String, _ used: Int64, _ cumulative: Int64, _ modelName: String, _ activity: TaskActivity = .active) -> TaskSnapshot {
            let counter = TokenCounters(input: used - 1_000, cachedInput: 5_000, output: 1_000, reasoningOutput: 200, total: used)!
            let total = TokenCounters(input: cumulative - 10_000, cachedInput: 10_000, output: 10_000, reasoningOutput: 1_000, total: cumulative)!
            return TaskSnapshot(task: TaskSummary(id: id, title: title, updatedAt: now, model: modelName, activity: activity),
                context: .available(ContextSnapshot(latestResponse: counter, cumulative: total, modelContextWindow: 258_400)!, source))
        }
        model.tasks = [snapshot("demo-root", "Polish the onboarding flow", 72_180, 820_000, "Main model"),
                       snapshot("demo-tests", "Add keyboard shortcuts", 44_600, 230_000, "Fast model", .idle),
                       snapshot("demo-docs", "Update the setup guide", 23_700, 120_000, "Main model", .completed)]
        model.track(.pinned("demo-root"))
        model.connectionIssue = nil
        model.agentDiscovery = AgentDiscoverySnapshot(rootID: "demo-root", tasks: [
            snapshot("demo-ui", "Interface review", 45_800, 320_000, "Main model"),
            snapshot("demo-access", "Accessibility checks", 33_200, 190_000, "Fast model"),
            snapshot("demo-regression", "Regression tests", 61_300, 410_000, "Fast model", .completed)
        ], exhaustive: true)
        model.account = AccountUsageSnapshot(quotas: .available([
            QuotaBucket(id: "demo-account", name: "Codex", windows: [
                QuotaWindow(id: "short", usedPercentage: 28, windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
                QuotaWindow(id: "week", usedPercentage: 39, windowDurationMinutes: 10080, resetsAt: now.addingTimeInterval(172800))])
        ], source), dailyTokens: .available([
            DailyTokenUsage(day: "2026-09-04", tokens: 450_000), DailyTokenUsage(day: "2026-09-05", tokens: 280_000),
            DailyTokenUsage(day: "2026-09-06", tokens: 350_000), DailyTokenUsage(day: "2026-09-07", tokens: 520_000),
            DailyTokenUsage(day: "2026-09-08", tokens: 780_000), DailyTokenUsage(day: "2026-09-09", tokens: 610_000),
            DailyTokenUsage(day: "2026-09-10", tokens: 920_000)
        ], source))
        for name in ["compact", "agents", "history"] {
            model.back()
            if name == "agents" { model.openAgents() }
            if name == "history" { model.openHistory() }
            let host = NSHostingView(rootView: PanelRootView(model: model).environment(\.colorScheme, .dark))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 380)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear
            window.contentView = host
            window.setContentSize(NSSize(width: 300, height: 380))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 380)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 760,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("No bitmap") }
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Export pixels only: AppKit's PNG representation can add EXIF metadata.
            let url = output.appendingPathComponent(name + ".png")
            guard let pixels = bitmap.cgImage,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("No PNG destination") }
            CGImageDestinationAddImage(destination, pixels, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
            window.close()
        }
        print("Rendered three native views using synthetic demo data.")
    }
}
