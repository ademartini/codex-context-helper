import Foundation
import AppKit
import Darwin

struct DesktopAppInstance: Equatable, Sendable {
    var processID: Int32
    var launchedAt: Date

    @MainActor static func current() -> Self? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, let launch = app.launchDate else { return nil }
        return Self(processID: app.processIdentifier, launchedAt: launch)
    }
}

/// Reads diagnostic metadata only. No CLI, Accessibility, socket, or task-content requests.
actor DesktopSelectionRepository {
    private let root: URL
    private let byteBudget: Int
    private var process: DesktopAppInstance?
    private var cursors: [String: DesktopSelectionLogCursor] = [:]
    private var sessions: Set<String> = []
    private var pending: [DesktopViewRecord] = []
    private var reducer = DesktopViewSelection()
    private var minimumEventDate = Date.distantPast
    private var gaps: [String: (offset: Int64, observedAt: Date)] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex"),
         byteBudget: Int = 2 * 1024 * 1024) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.byteBudget = min(4 * 1024 * 1024, max(1, byteBudget))
    }

    func selection(for process: DesktopAppInstance?, now: Date = Date()) -> TaskSelectionEvidence {
        if self.process != process {
            self.process = process; cursors = [:]; sessions = []; pending = []; reducer = DesktopViewSelection()
            minimumEventDate = process?.launchedAt ?? now; gaps = [:]
        }
        guard let process else { return .unavailable(.disconnected) }
        do {
            let files = try discover(process: process, now: now)
            let paths = Set(files.map(\.path))
            if cursors.keys.contains(where: { !paths.contains($0) }) {
                invalidate(at: now)
            }
            cursors = cursors.filter { paths.contains($0.key) }
            var budget = byteBudget
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
            var more = false
            for file in files {
                let cursor: DesktopSelectionLogCursor
                if let existing = cursors[file.path] { cursor = existing }
                else {
                    cursor = DesktopSelectionLogCursor(root: root, path: file.path, launchedAt: process.launchedAt)
                    cursors[file.path] = cursor
                }
                guard budget > 0, ContinuousClock.now < deadline else { more = true; continue }
                let batch = try cursor.read(budget: budget, deadline: deadline, now: now)
                budget -= batch.bytes
                if batch.replaced { invalidate(at: now) }
                if cursor.sawCurrentProcessRecord { sessions.insert(file.session) }
                pending.append(contentsOf: batch.records.filter { $0.unorderedBarrier || $0.date >= minimumEventDate })
                if pending.count > 4096 { invalidate(at: now); more = true }
                more = more || batch.more
            }
            guard sessions.count <= 1 else { return .unavailable(.ambiguousSelection) }
            // Never expose a historical positive while a later negative may still be unread.
            guard !more else { return .unavailable(.connecting) }
            for record in pending where record.unorderedBarrier {
                gaps[record.path] = (record.offset, now)
                reducer = DesktopViewSelection(reason: .unsupportedSchema)
            }
            pending.removeAll { $0.unorderedBarrier }
            pending.sort { $0.date == $1.date ? ($0.path == $1.path ? $0.offset < $1.offset : $0.path < $1.path) : $0.date < $1.date }
            for record in pending {
                // An untimestamped gap has no order across files. Require a later byte
                // in that file, or an event newer than when we observed the gap.
                guard gaps.allSatisfy({ path, gap in
                    (record.path == path && record.offset > gap.offset) || record.date > gap.observedAt
                }) else { continue }
                reducer.consume(record)
                if record.view?.active == true, record.view?.eligible == true { gaps = [:] }
            }
            pending.removeAll(keepingCapacity: false)
            return reducer.evidence
        } catch {
            invalidate(at: now)
            return .unavailable(.unsupportedSchema)
        }
    }

    private func invalidate(at date: Date) {
        reducer = DesktopViewSelection(reason: .unsupportedSchema)
        pending = []; gaps = [:]; minimumEventDate = max(minimumEventDate, date)
    }

    private struct LogFile { var path: String; var session: String }
    private static let filename = try! NSRegularExpression(pattern: "^codex-desktop-([0-9a-fA-F-]{36})-([0-9]+)-t0-i[0-9]+-[0-9]{6}-[0-4]\\.log$")

    private func discover(process: DesktopAppInstance, now: Date) throws -> [LogFile] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let launchDay = calendar.startOfDay(for: process.launchedAt)
        var day = calendar.startOfDay(for: now), files: [LogFile] = [], visited = 0
        // Bounded startup history. An older idle selection stays unknown until a new view event.
        for _ in 0..<7 where day >= launchDay {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            var ancestor = root
            for part in directory.path.dropFirst(root.path.count + 1).split(separator: "/") {
                ancestor.appendPathComponent(String(part))
                var info = stat()
                if lstat(ancestor.path, &info) != 0 {
                    if errno == ENOENT { break }
                    throw SessionLogSchema.SchemaError.invalid
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw SessionLogSchema.SchemaError.invalid }
            }
            if let stream = opendir(directory.path) {
                defer { closedir(stream) }
                while let entry = readdir(stream) {
                    visited += 1
                    guard visited <= 2048 else { throw SessionLogSchema.SchemaError.invalid }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                    }
                    guard let match = Self.filename.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                          let idRange = Range(match.range(at: 1), in: name),
                          let pidRange = Range(match.range(at: 2), in: name),
                          Int32(name[pidRange]) == process.processID,
                          let session = UUID(uuidString: String(name[idRange])) else { continue }
                    files.append(LogFile(path: directory.appendingPathComponent(name).path, session: session.uuidString.lowercased()))
                    guard files.count <= 128 else { throw SessionLogSchema.SchemaError.invalid }
                }
            } else if errno != ENOENT { throw SessionLogSchema.SchemaError.invalid }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return files.sorted { $0.path < $1.path }
    }
}

struct DesktopViewRecord: Equatable {
    struct View: Equatable {
        var id: String
        var window: String
        var contents: String
        var active: Bool
        var eligible: Bool
        func sameView(as other: Self) -> Bool { id == other.id && window == other.window && contents == other.contents }
    }
    var date: Date
    var path: String
    var offset: Int64
    /// Nil is a malformed named event or an integrity barrier.
    var view: View?
    var unorderedBarrier = false
}

struct DesktopViewSelection {
    private var selected: DesktopViewRecord.View?
    private var latest: DesktopViewRecord?
    private var ambiguousThrough: Date?
    private var reason: UnavailableReason
    init(reason: UnavailableReason = .noData) { self.reason = reason }
    var evidence: TaskSelectionEvidence { selected.map { .localTask($0.id) } ?? .unavailable(reason) }

    mutating func consume(_ record: DesktopViewRecord) {
        if let ambiguousThrough, record.date <= ambiguousThrough { return }
        if let latest {
            guard record.date >= latest.date else { return }
            if record.date == latest.date {
                if record.path == latest.path, record.offset <= latest.offset { return }
                if record.path != latest.path, record.view != latest.view {
                    selected = nil; reason = .ambiguousSelection; ambiguousThrough = record.date; self.latest = record; return
                }
            }
        }
        latest = record
        guard let view = record.view else { selected = nil; reason = .unsupportedSchema; return }
        if view.active {
            if view.eligible { selected = view }
        } else if let selected, view.sameView(as: selected) {
            self.selected = nil; reason = .noData
        }
    }
}

/// Confined to the repository actor; keeps only a bounded unfinished line and metadata records.
private final class DesktopSelectionLogCursor {
    struct Batch { var bytes: Int; var records: [DesktopViewRecord]; var more: Bool; var replaced: Bool }
    let root: URL
    let path: String
    let launchedAt: Date
    private var identity: [UInt64]?
    private var offset: Int64 = 0
    private var prefix = Data(), anchor = Data(), line = Data()
    private var skipping = false
    private var lastDate: Date
    private let dates = ISO8601DateFormatter()
    private static let allowedFields: Set<String> = ["active", "conversationId", "rendererWindowId", "rendererWebContentsId",
                                                     "rendererWindowAppearance", "rendererWindowFocused", "rendererWindowVisible"]
    private(set) var sawCurrentProcessRecord = false
    private(set) var hasUnreadData = true

    init(root: URL, path: String, launchedAt: Date) {
        self.root = root; self.path = path; self.launchedAt = launchedAt; lastDate = launchedAt
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(budget: Int, deadline: ContinuousClock.Instant, now: Date) throws -> Batch {
        let descriptor = try SessionLogReader.openContained(root: root, path: path)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SessionLogSchema.SchemaError.invalid }
        let nextIdentity = [UInt64(info.st_dev), UInt64(info.st_ino)]
        let samePrefix = try bytes(descriptor, at: 0, count: prefix.count) == prefix
        let sameAnchor = try bytes(descriptor, at: offset - Int64(anchor.count), count: anchor.count) == anchor
        let replaced = identity != nil && (identity != nextIdentity || info.st_size < offset
            || !samePrefix || !sameAnchor)
        if replaced {
            offset = 0; line = Data(); prefix = Data(); anchor = Data(); skipping = false
            lastDate = launchedAt; sawCurrentProcessRecord = false
        }
        identity = nextIdentity
        var consumed = 0, records: [DesktopViewRecord] = []
        let target = info.st_size
        while offset < target, consumed < budget, ContinuousClock.now < deadline {
            let data = try bytes(descriptor, at: offset, count: min(64 * 1024, budget - consumed, Int(target - offset)))
            guard !data.isEmpty else { throw SessionLogSchema.SchemaError.invalid }
            for byte in data {
                offset += 1
                if byte == 10 {
                    if skipping { records.append(barrier(unordered: true)) }
                    else if let record = parse(now: now) { records.append(record) }
                    line.removeAll(keepingCapacity: true); skipping = false
                } else if !skipping {
                    if line.count < 64 * 1024 { line.append(byte) }
                    else { line.removeAll(keepingCapacity: false); skipping = true }
                }
            }
            consumed += data.count
        }
        prefix = try bytes(descriptor, at: 0, count: min(64, Int(offset)))
        anchor = try bytes(descriptor, at: max(0, offset - 64), count: min(64, Int(offset)))
        guard fstat(descriptor, &info) == 0, info.st_size >= offset else { throw SessionLogSchema.SchemaError.invalid }
        hasUnreadData = offset < info.st_size || !line.isEmpty || skipping
        return Batch(bytes: consumed, records: records, more: hasUnreadData, replaced: replaced)
    }

    private func bytes(_ descriptor: Int32, at position: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, position) }
        guard actual >= 0 else { throw SessionLogSchema.SchemaError.invalid }
        data.count = actual; return data
    }

    private func barrier(unordered: Bool = false) -> DesktopViewRecord {
        DesktopViewRecord(date: lastDate, path: path, offset: offset, view: nil, unorderedBarrier: unordered)
    }

    private func parse(now: Date) -> DesktopViewRecord? {
        guard let text = String(data: line, encoding: .utf8) else { return barrier(unordered: true) }
        if text.hasPrefix("[file-logger] dropped ") { return barrier(unordered: true) }
        // Once this file belongs to the current process lifetime, unrelated log
        // lines need no timestamp parsing. Only view events affect selection.
        if sawCurrentProcessRecord, !text.contains("thread_stream_view_activity_changed") { return nil }
        let header = text.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        let namedEvent = header.count >= 4 && header[1] == "info" && header[2] == "[electron-message-handler]"
            && header[3] == "thread_stream_view_activity_changed"
        guard let first = header.first, let date = dates.date(from: String(first)) else {
            return namedEvent ? barrier(unordered: true) : nil
        }
        guard date >= launchedAt else { return nil }
        guard date <= now.addingTimeInterval(2) else { return namedEvent ? barrier(unordered: true) : nil }
        lastDate = max(lastDate, date); sawCurrentProcessRecord = true
        guard namedEvent else { return nil }
        guard header.count == 5 else { return barrier() }
        let tokens = header[4].split(separator: " ")
        guard tokens.count <= 32 else { return barrier() }
        var fields: [String: String] = [:]
        for token in tokens {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return barrier() }
            let key = String(pair[0])
            if Self.allowedFields.contains(key) {
                guard fields[key] == nil else { return barrier() }
                fields[key] = String(pair[1])
            }
        }
        guard let rawID = fields["conversationId"], let id = UUID(uuidString: rawID), rawID.lowercased() == id.uuidString.lowercased(),
              let window = fields["rendererWindowId"], let windowNumber = Int32(window), windowNumber > 0,
              let contents = fields["rendererWebContentsId"], let contentsNumber = Int32(contents), contentsNumber > 0,
              let active = fields["active"].flatMap(Bool.init), let focused = fields["rendererWindowFocused"].flatMap(Bool.init),
              let visible = fields["rendererWindowVisible"].flatMap(Bool.init), let appearance = fields["rendererWindowAppearance"] else { return barrier() }
        return DesktopViewRecord(date: date, path: path, offset: offset,
                                 view: .init(id: id.uuidString.lowercased(), window: window, contents: contents, active: active,
                                             eligible: focused && visible && appearance == "primary"))
    }
}
