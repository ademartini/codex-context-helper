import Foundation
import Darwin

struct SessionReadResult: Equatable, Sendable {
    var context: Metric<ContextSnapshot>
    var model: String?
    var moreData: Bool
    var agentName: String?
    var occupancyVerified: Bool { SessionLogSchema.occupancyVerified }
}

/// Confined to ContextSnapshotRepository's actor. Regular files only; never follows a path component symlink.
final class SessionLogReader {
    private let descriptor: Int32
    private let path: String
    private let threadID: String
    private let inode: ino_t
    private let device: dev_t
    private let maximumLineBytes: Int
    private let byteBudget: Int
    private var line = Data()
    private var skippingOversizedLine = false
    private var metadataVerified = false
    private var sawMetadata = false
    private var inheritedIDs = Set<String>()
    private var permanentlyUnsupported = false
    private var failure: UnavailableReason?
    private var context: ContextSnapshot?
    private var counterAt: Date?
    private var model: String?
    private var agentName: String?
    private(set) var offset: UInt64 = 0
    var bufferedBytes: Int { line.count }

    init(root: URL, path: String, threadID: String, maximumLineBytes: Int = 16 * 1024 * 1024, byteBudget: Int = 32 * 1024 * 1024) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.threadID = threadID
        self.maximumLineBytes = min(16 * 1024 * 1024, max(1, maximumLineBytes))
        self.byteBudget = min(32 * 1024 * 1024, max(1, byteBudget))
        descriptor = try Self.openContained(root: root, path: self.path)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw SessionLogSchema.SchemaError.invalid }
        inode = info.st_ino; device = info.st_dev
    }
    deinit { Darwin.close(descriptor) }

    static func openContained(root: URL, path: String) throws -> Int32 {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized.hasPrefix(base + "/") else { throw SessionLogSchema.SchemaError.invalid }
        let components = normalized.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw SessionLogSchema.SchemaError.invalid }
        var parent = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw SessionLogSchema.SchemaError.invalid }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(parent, component, flags)
            Darwin.close(parent)
            guard next >= 0 else { throw SessionLogSchema.SchemaError.invalid }
            parent = next
        }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(parent); throw SessionLogSchema.SchemaError.invalid
        }
        return parent
    }

    func refresh(now: Date = Date()) -> SessionReadResult {
        var info = stat(), current = stat()
        guard fstat(descriptor, &info) == 0, lstat(path, &current) == 0,
              info.st_nlink > 0, current.st_ino == inode, current.st_dev == device,
              current.st_mode & S_IFMT == S_IFREG, info.st_size >= Int64(offset) else {
            failure = .missingSession
            return result(now: now, more: false)
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        var consumed = 0
        var bytes = [UInt8](repeating: 0, count: min(64 * 1024, byteBudget))
        while consumed < byteBudget && ContinuousClock.now < deadline {
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, byteBudget - consumed))
            guard count >= 0 else { failure = .missingSession; break }
            if count == 0 { break }
            consumed += count; offset += UInt64(count)
            consume(Data(bytes.prefix(count)))
        }
        _ = fstat(descriptor, &info)
        return result(now: now, more: Int64(offset) < info.st_size)
    }

    private func consume(_ data: Data) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !skippingOversizedLine {
                if end - start > maximumLineBytes - line.count {
                    skippingOversizedLine = true; line.removeAll(keepingCapacity: false); failure = .unsupportedSchema
                } else { line.append(data[start..<end]) }
            }
            guard let newline else { return }
            if !skippingOversizedLine && !line.isEmpty { decodeLine() }
            skippingOversizedLine = false
            line.removeAll(keepingCapacity: false)
            start = newline + 1
        }
    }

    private func decodeLine() {
        do {
            switch try SessionLogSchema.decode(line) {
            case .metadata(let id, let version, let name, let parentID, let forkID):
                if !sawMetadata {
                    sawMetadata = true
                    metadataVerified = id == threadID && version == AppServerProcess.supportedVersion
                    permanentlyUnsupported = !metadataVerified
                    agentName = metadataVerified ? name : nil
                } else if version != AppServerProcess.supportedVersion || (id != threadID && !inheritedIDs.contains(id)) {
                    permanentlyUnsupported = true
                }
                if permanentlyUnsupported { failure = .unsupportedSchema; return }
                // Forked agents embed ancestor metadata in their copied history. Only declared
                // parent/fork chains are accepted; the first verified header owns this file.
                for inherited in [parentID, forkID].compactMap({ $0 }) where inheritedIDs.count < 200 {
                    guard inherited.utf8.count <= 256 else {
                        permanentlyUnsupported = true; failure = .unsupportedSchema; return
                    }
                    inheritedIDs.insert(inherited)
                }
            case .model(let nextModel):
                if let model, model != nextModel { context = nil; counterAt = nil; failure = .updatingContext }
                model = nextModel
            case .contextReset:
                context = nil; counterAt = nil; failure = .updatingContext
            case .counters(let value, let date):
                guard metadataVerified, !permanentlyUnsupported else { failure = .unsupportedSchema; return }
                context = value; counterAt = date; failure = nil
            case .ignored: break
            }
        } catch { failure = .unsupportedSchema }
    }

    private func result(now: Date, more: Bool) -> SessionReadResult {
        let metric: Metric<ContextSnapshot>
        if let failure { metric = .unavailable(failure) }
        else if more { metric = .unavailable(.connecting) }
        else if let context {
            metric = .available(context, DataProvenance(source: .sessionLog, schemaVersion: SessionLogSchema.version,
                                                       observedAt: now, counterAt: counterAt))
        } else { metric = .unavailable(.noData) }
        return SessionReadResult(context: metric, model: model, moreData: more, agentName: agentName)
    }
}
