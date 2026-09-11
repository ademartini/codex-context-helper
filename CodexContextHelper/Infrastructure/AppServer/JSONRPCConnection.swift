import Foundation
import Darwin

/// Errors deliberately contain no server text, request parameters, or subprocess output.
enum AppServerError: Error, Equatable, Sendable {
    case forbiddenMethod, invalidParameters, notConnected, malformedResponse, frameTooLarge
    case timeout, disconnected, unsupportedMethod, rejectedParameters, signedOut, serverFailure, tooManyRequests

    var unavailableReason: UnavailableReason {
        switch self {
        case .signedOut: .signedOut
        case .malformedResponse, .frameTooLarge, .unsupportedMethod, .rejectedParameters: .unsupportedSchema
        default: .disconnected
        }
    }
}

/// Integer values are never routed through Double; micro-credit amounts must remain exact.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .bool(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue? { if case .object(let object) = self { object[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
}

protocol AppServerRequesting: Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
}

/// Newline-delimited JSON-RPC over a single directly launched, approved process.
actor JSONRPCConnection: AppServerRequesting {
    enum Health: Equatable, Sendable { case stopped, connecting, connected, failed(AppServerError) }
    private(set) var health: Health = .stopped
    private let process: Process
    private let requestTimeout: Duration
    private let maximumFrameBytes: Int
    private var reader: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var buffer = Data()
    private var unsupportedMethods = Set<String>()
    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var deadlines: [Int64: Task<Void, Never>] = [:]

    init(process: Process, requestTimeout: Duration = .seconds(10), maximumFrameBytes: Int = 16 * 1024 * 1024) {
        self.process = process
        self.requestTimeout = requestTimeout
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    func start() async throws {
        guard health == .stopped, cleanupTask == nil, let output = process.standardOutput as? Pipe,
              process.standardInput is Pipe else { throw AppServerError.notConnected }
        let inputFD = (process.standardInput as! Pipe).fileHandleForWriting.fileDescriptor
        guard fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK) != -1 else { throw AppServerError.disconnected }
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1 else { throw AppServerError.disconnected }
        health = .connecting
        process.terminationHandler = { [weak self] _ in Task { await self?.fail(.disconnected) } }
        do { try process.run() } catch { fail(.disconnected); throw AppServerError.disconnected }
        let handle = output.fileHandleForReading
        // Await each chunk's consumption so a busy child cannot enqueue unbounded payloads.
        reader = Task.detached(priority: .utility) { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while !Task.isCancelled {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = Data(bytes.prefix(count))
                guard let self, await self.receive(chunk) else { return }
            }
            await self?.fail(.disconnected)
        }
        do {
            let response = try await send(method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("codex_context_helper"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            guard case .object = response else { throw AppServerError.malformedResponse }
            try write(.object(["method": .string("initialized")]))
            health = .connected
        } catch {
            let safeError = error as? AppServerError ?? .disconnected
            fail(safeError)
            throw safeError
        }
    }

    func request(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try Self.validate(method: method, params: params)
        guard health == .connected else { throw AppServerError.notConnected }
        guard !unsupportedMethods.contains(method) else { throw AppServerError.unsupportedMethod }
        do { return try await send(method: method, params: params) }
        catch AppServerError.unsupportedMethod {
            unsupportedMethods.insert(method)
            throw AppServerError.unsupportedMethod
        }
    }

    /// Both the method and potentially mutating/read-content options are checked at the wire boundary.
    static func validate(method: String, params: JSONValue) throws {
        guard case .object(let fields) = params else { throw AppServerError.invalidParameters }
        let allowed: Set<String>
        switch method {
        case "thread/list":
            allowed = ["cursor", "limit", "archived", "sortKey", "sortDirection", "sourceKinds", "useStateDbOnly", "ancestorThreadId", "parentThreadId", "searchTerm"]
            guard fields["useStateDbOnly"] == .bool(true) else { throw AppServerError.invalidParameters }
        case "thread/read":
            allowed = ["threadId", "includeTurns"]
            guard fields["includeTurns"] == .bool(false), fields["threadId"]?.string?.isEmpty == false else { throw AppServerError.invalidParameters }
        case "account/read":
            allowed = ["refreshToken"]
            guard fields["refreshToken"] == .bool(false) else { throw AppServerError.invalidParameters }
        case "account/rateLimits/read": allowed = []
        case "account/usage/read": allowed = ["threadId"]
        default: throw AppServerError.forbiddenMethod
        }
        guard Set(fields.keys).isSubset(of: allowed) else { throw AppServerError.invalidParameters }
    }

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        guard pending.count < 32, nextID < Int64.max else { throw AppServerError.tooManyRequests }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.fail(.timeout)
                }
                do {
                    try write(.object(["id": .integer(id), "method": .string(method), "params": params]))
                } catch { fail(error as? AppServerError ?? .disconnected) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func write(_ value: JSONValue) throws {
        guard let pipe = process.standardInput as? Pipe, process.isRunning else { throw AppServerError.disconnected }
        var data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw AppServerError.invalidParameters }
        guard data.count <= min(maximumFrameBytes, 16_384) else { throw AppServerError.invalidParameters }
        data.append(10)
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { throw AppServerError.disconnected }
            }
        }
    }

    /// Cap each frame before append, including frames split across arbitrary read boundaries.
    private func receive(_ chunk: Data) -> Bool {
        guard health == .connecting || health == .connected else { return false }
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let end = newline ?? chunk.endIndex
            let count = chunk.distance(from: start, to: end)
            guard count <= maximumFrameBytes - buffer.count else { fail(.frameTooLarge); return false }
            buffer.append(contentsOf: chunk[start..<end])
            if let newline {
                if !buffer.isEmpty, !consumeFrame(buffer) { return false }
                buffer.removeAll(keepingCapacity: false)
                start = chunk.index(after: newline)
            } else { break }
        }
        return true
    }

    private func consumeFrame(_ data: Data) -> Bool {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = message else {
            fail(.malformedResponse); return false
        }
        // Notifications are ephemeral. Never hydrate or cache their content or issue approval responses.
        if message["method"] != nil {
            guard message["method"]?.string != nil, message["id"] == nil else { fail(.forbiddenMethod); return false }
            return true
        }
        guard let id = message["id"]?.integer else { fail(.malformedResponse); return false }
        guard let continuation = pending.removeValue(forKey: id) else { return true }
        deadlines.removeValue(forKey: id)?.cancel()
        if let error = message["error"] {
            let safe: AppServerError
            switch error["code"]?.integer {
            case -32601: safe = .unsupportedMethod
            case -32602: safe = .rejectedParameters
            case 401, 403: safe = .signedOut
            default: safe = .serverFailure
            }
            continuation.resume(throwing: safe)
        } else if let result = message["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: AppServerError.malformedResponse)
            fail(.malformedResponse); return false
        }
        return true
    }

    private func cancel(_ id: Int64) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func fail(_ error: AppServerError) {
        if case .failed = health { return }
        guard health != .stopped else { return }
        health = .failed(error)
        cleanup(error: error)
    }

    @discardableResult
    func close() async -> Bool {
        health = .stopped
        cleanup(error: .disconnected)
        let stopped = await cleanupTask?.value ?? true
        if !stopped { health = .failed(.disconnected) }
        return stopped
    }

    private func cleanup(error: AppServerError) {
        reader?.cancel(); reader = nil
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        buffer.removeAll(keepingCapacity: false)
        process.terminationHandler = nil
        try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        guard cleanupTask == nil else { return }
        let process = process
        cleanupTask = Task.detached(priority: .utility) {
            // Never call Foundation.waitUntilExit on a cooperative executor: it can wait
            // forever in a run loop even after the OS has reaped the child.
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            for _ in 0..<100 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let stopped = !process.isRunning
            try? (process.standardOutput as? Pipe)?.fileHandleForReading.close()
            try? (process.standardOutput as? Pipe)?.fileHandleForWriting.close()
            try? (process.standardInput as? Pipe)?.fileHandleForReading.close()
            return stopped
        }
    }
}
