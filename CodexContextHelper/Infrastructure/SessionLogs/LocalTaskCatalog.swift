import Foundation
import Darwin

struct LocalCatalogSnapshot: Equatable, Sendable {
    var tasks: [TaskSummary]
    var issue: UnavailableReason?
    var conflictedIDs: Set<String> = []
}

/// A partial catalog of recent saved sessions. Enumeration resumes between refreshes, so a
/// large directory does not repeatedly hide everything beyond the first scan slice.
actor LocalTaskCatalog {
    nonisolated let root: URL
    private let maximumTasks: Int
    private let entriesPerRefresh: Int
    private let maximumHeaderBytes: Int
    private var enumerator: FileManager.DirectoryEnumerator?
    private var entries: [String: Entry] = [:]
    private var duplicateIDs: [String: Int] = [:]
    private var generation = 0
    private var completedScan = false
    private var malformedInScan = false
    private var lastMalformed = false
    private var cacheCursor = 0
    private let scanErrors = ScanErrors()

    private struct Signature: Equatable {
        var inode: ino_t
        var device: dev_t
        var size: off_t
        var seconds: Int
        var nanoseconds: Int
        init(_ info: stat) {
            inode = info.st_ino; device = info.st_dev; size = info.st_size
            seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
        }
    }
    private struct Entry {
        var task: TaskSummary
        var signature: Signature
        var generation: Int
    }
    private final class ScanErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var permissionDenied = false
        func record(_ error: Error) {
            let error = error as NSError
            if error.code == NSFileReadNoPermissionError || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
                lock.withLock { permissionDenied = true }
            }
        }
        var denied: Bool { lock.withLock { permissionDenied } }
        func reset() { lock.withLock { permissionDenied = false } }
    }

    init(root: URL = CodexDataLocation.sessions, maximumTasks: Int = 512, entriesPerRefresh: Int = 128,
         maximumHeaderBytes: Int = 64 * 1024) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumTasks = min(512, max(1, maximumTasks))
        self.entriesPerRefresh = min(512, max(1, entriesPerRefresh))
        self.maximumHeaderBytes = min(256 * 1024, max(1, maximumHeaderBytes))
    }

    func refresh() -> LocalCatalogSnapshot {
        guard !Task.isCancelled else { return snapshot() }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else {
            let reason: UnavailableReason = [EACCES, EPERM].contains(errno) ? .permissionDenied : .noData
            stop(); return LocalCatalogSnapshot(tasks: [], issue: reason)
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            stop(); return LocalCatalogSnapshot(tasks: [], issue: .unsupportedSchema)
        }
        guard access(root.path, R_OK | X_OK) == 0 else {
            stop(); return LocalCatalogSnapshot(tasks: [], issue: .permissionDenied)
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(75))
        // Refresh a rotating subset even while enumeration is traversing older directories.
        // This catches appends, deletion and replacement without restarting the scan.
        let cachedPaths = entries.keys.sorted()
        if !cachedPaths.isEmpty {
            for _ in 0..<min(16, cachedPaths.count) {
                if Task.isCancelled || ContinuousClock.now >= deadline { break }
                cacheCursor %= cachedPaths.count
                inspect(cachedPaths[cacheCursor], markingSeen: false)
                cacheCursor += 1
            }
        }
        if enumerator == nil {
            generation += 1
            malformedInScan = false
            scanErrors.reset()
            let errors = scanErrors
            enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles], errorHandler: { _, error in
                errors.record(error); return true
            })
            if enumerator == nil { return LocalCatalogSnapshot(tasks: [], issue: .permissionDenied) }
        }
        for _ in 0..<entriesPerRefresh {
            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            guard let url = enumerator?.nextObject() as? URL else {
                enumerator = nil
                entries = entries.filter { $0.value.generation == generation }
                duplicateIDs = duplicateIDs.filter { $0.value == generation }
                lastMalformed = malformedInScan
                completedScan = true
                break
            }
            // Codex uses year/month/day directories. Bound unexpected nesting and never
            // follow symlink entries. Header reads additionally walk with O_NOFOLLOW.
            let depth = url.pathComponents.count - root.pathComponents.count
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                if depth >= 8 { enumerator?.skipDescendants() }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG, url.pathExtension == "jsonl" else { continue }
            inspect(url.path, markingSeen: true)
        }
        return snapshot()
    }

    private func inspect(_ path: String, markingSeen: Bool) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            entries.removeValue(forKey: path); return
        }
        let signature = Signature(info)
        if var entry = entries[path], entry.signature == signature {
            if markingSeen { entry.generation = generation; entries[path] = entry }
            return
        }
        do {
            let descriptor = try SessionLogReader.openContained(root: root, path: path)
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, Signature(opened) == signature else {
                entries.removeValue(forKey: path); return
            }
            var bytes = [UInt8](repeating: 0, count: maximumHeaderBytes)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 10),
                  case .metadata(let id, _, let name, let parentID, _) = try SessionLogSchema.decode(Data(bytes[..<newline])),
                  parentID != id else {
                malformedInScan = true; entries.removeValue(forKey: path); return
            }
            // Verify path identity again after reading, including replacement during a read.
            var current = stat()
            guard lstat(path, &current) == 0, Signature(current) == signature else {
                entries.removeValue(forKey: path); return
            }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            let created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
            let date = DateFormatter()
            date.dateStyle = .short; date.timeStyle = .short
            let title = "Session \(id.suffix(8)) · \(date.string(from: created))"
            let task = TaskSummary(id: id, title: title, updatedAt: modified, recencyAt: modified,
                                   parentThreadID: parentID, sessionPath: path, agentName: name)
            if entries.contains(where: { $0.key != path && $0.value.task.id == id }) { duplicateIDs[id] = generation }
            entries[path] = Entry(task: task, signature: signature, generation: markingSeen ? generation : (entries[path]?.generation ?? generation))
            if entries.count > maximumTasks {
                let oldest = entries.min { left, right in
                    left.value.task.updatedAt == right.value.task.updatedAt ? left.key < right.key : left.value.task.updatedAt < right.value.task.updatedAt
                }!.key
                entries.removeValue(forKey: oldest)
            }
            let retainedIDs = Set(entries.values.map(\.task.id))
            duplicateIDs = duplicateIDs.filter { retainedIDs.contains($0.key) }
        } catch {
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { scanErrors.record(error) }
            else { malformedInScan = true }
            entries.removeValue(forKey: path)
        }
    }

    private func snapshot() -> LocalCatalogSnapshot {
        let grouped = Dictionary(grouping: entries.values.map(\.task), by: \.id)
        let conflictedIDs = Set(duplicateIDs.keys).union(grouped.filter { $0.value.count > 1 }.keys)
        // Two retained files claiming one identity cannot safely select a context reader.
        let tasks = grouped.filter { !conflictedIDs.contains($0.key) }.values.compactMap(\.first).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        let issue: UnavailableReason?
        if !tasks.isEmpty { issue = nil }
        else if scanErrors.denied { issue = .permissionDenied }
        else if !completedScan && enumerator != nil { issue = .connecting }
        else if malformedInScan || lastMalformed || !entries.isEmpty { issue = .unsupportedSchema }
        else { issue = .noData }
        return LocalCatalogSnapshot(tasks: tasks, issue: issue, conflictedIDs: conflictedIDs)
    }

    func stop() {
        enumerator = nil; entries.removeAll(); completedScan = false
        duplicateIDs.removeAll()
        malformedInScan = false; lastMalformed = false; cacheCursor = 0; scanErrors.reset()
    }
}
