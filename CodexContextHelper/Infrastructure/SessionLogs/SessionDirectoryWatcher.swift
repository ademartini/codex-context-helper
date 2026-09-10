import Foundation
import Darwin

/// All mutable state is confined to queue; cancel handlers own and close their descriptors.
final class SessionDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-context-helper.session-events", qos: .utility)
    private let root: URL
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var paths: [String: String] = [:]
    private var pending = Set<String>()
    private var debounce: DispatchWorkItem?
    private var callback: (@Sendable (Set<String>) -> Void)?

    init(root: URL) { self.root = root }

    func update(paths requested: [String: String], onChange: @escaping @Sendable (Set<String>) -> Void) {
        queue.async { [self] in
            callback = onChange
            let entries = requested.sorted { $0.key < $1.key }
            let bounded = Dictionary(uniqueKeysWithValues: entries.prefix(10).map { ($0.key, $0.value) })
            for id in Array(sources.keys) where bounded[id] != paths[id] {
                sources.removeValue(forKey: id)?.cancel(); paths.removeValue(forKey: id)
            }
            for (id, path) in bounded where sources[id] == nil {
                guard let fd = try? SessionLogReader.openContained(root: root, path: path) else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
                source.setEventHandler { [weak self] in self?.changed(id) }
                source.setCancelHandler { Darwin.close(fd) }
                sources[id] = source; paths[id] = path
                source.resume()
            }
        }
    }
    private func changed(_ id: String) {
        if let source = sources[id], !source.data.intersection([.delete, .rename]).isEmpty {
            sources.removeValue(forKey: id)?.cancel(); paths.removeValue(forKey: id)
        }
        pending.insert(id)
        guard debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            let changed = self.pending; self.pending.removeAll()
            self.callback?(changed)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func synchronize() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func stop() {
        queue.async { [self] in
            debounce?.cancel(); debounce = nil
            sources.values.forEach { $0.cancel() }; sources.removeAll(); paths.removeAll(); pending.removeAll(); callback = nil
        }
    }
    deinit { sources.values.forEach { $0.cancel() }; debounce?.cancel() }
}
