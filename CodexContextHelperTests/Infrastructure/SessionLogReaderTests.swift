import XCTest
import Darwin
@testable import CodexContextHelper

final class SessionLogReaderTests: XCTestCase {
    func testCompatibleDifferentProducerVersionsAndMixedInheritedHistory() throws {
        for version in ["0.153.5", "0.160.0", "1.0.0-alpha.2"] {
            try withFixture { root, file in
                let source = try String(contentsOf: file, encoding: .utf8)
                let updated = source.replacingOccurrences(of: "\"cli_version\":\"0.153.4\"", with: "\"cli_version\":\"\(version)\",\"parent_thread_id\":\"parent\"")
                try updated.write(to: file, atomically: true, encoding: .utf8)
                let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
                XCTAssertEqual(reader.refresh().context.provenance?.producerVersions, [version])
                try append(#"{"type":"session_meta","payload":{"id":"parent","cli_version":"0.152.0"}}"#, to: file)
                try append(String(source.split(separator: "\n").last!), to: file)
                let mixed = reader.refresh()
                XCTAssertEqual(mixed.context.value?.latestResponse.total, 250)
                XCTAssertEqual(mixed.context.provenance?.producerVersions, ["0.152.0", version].sorted())
                XCTAssertEqual(mixed.context.provenance?.schemaVersion, "session-counters-v2")
            }
        }
    }
    func testMalformedAndOversizedProducerVersionsAreRejected() throws {
        for version in ["", "unexpected version", String(repeating: "1", count: 129)] {
            try withFixture { root, file in
                let source = try String(contentsOf: file, encoding: .utf8)
                try source.replacingOccurrences(of: "\"cli_version\":\"0.153.4\"", with: "\"cli_version\":\"\(version)\"")
                    .write(to: file, atomically: true, encoding: .utf8)
                let result = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root").refresh()
                XCTAssertEqual(result.context.unavailableReason, .unsupportedSchema)
            }
        }
    }
    func testMalformedInheritedMetadataCannotBeClearedByLaterCounters() throws {
        try withFixture { root, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNotNil(reader.refresh().context.value)
            try append(#"{"type":"session_meta","payload":{"id":"fixture-root","cli_version":"bad version"}}"#, to: file)
            try append(String(source.split(separator: "\n").last!), to: file)
            XCTAssertEqual(reader.refresh().context.unavailableReason, .unsupportedSchema)
        }
    }
    func testProvenanceDecodesWithoutProducerVersionsAndBoundsDiagnostics() throws {
        let old = #"{"source":"sessionLog","schemaVersion":"old","observedAt":0,"measurement":"exact","invalidated":false}"#
        let decoded = try JSONDecoder().decode(DataProvenance.self, from: Data(old.utf8))
        XCTAssertNil(decoded.producerVersions)
        let provenance = DataProvenance(source: .sessionLog, schemaVersion: "test", producerVersions: (0..<100).map { "0.\($0).0" } + ["bad version"])
        XCTAssertEqual(provenance.producerVersions?.count, 32)
        XCTAssertFalse(provenance.producerVersions?.contains("bad version") ?? true)
    }
    func testOversizedInheritedIdentityIsRejected() throws {
        try withFixture { root, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            try source.replacingOccurrences(of: "\"cli_version\":\"0.153.4\"", with: "\"cli_version\":\"0.153.4\",\"parent_thread_id\":\"\(String(repeating: "x", count: 257))\"")
                .write(to: file, atomically: true, encoding: .utf8)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertEqual(reader.refresh().context.unavailableReason, .unsupportedSchema)
        }
    }
    func testDeclaredInheritedMetadataDoesNotReplaceAgentIdentity() throws {
        try withFixture { root, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            try source.replacingOccurrences(of: "\"cli_version\":\"0.153.4\"", with: "\"cli_version\":\"0.153.4\",\"parent_thread_id\":\"parent\",\"agent_nickname\":\"Agent Name\"")
                .write(to: file, atomically: true, encoding: .utf8)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNotNil(reader.refresh().context.value)
            try append(#"{"type":"session_meta","payload":{"id":"parent","cli_version":"0.153.4","agent_nickname":"Parent Name"}}"#, to: file)
            try append(String(source.split(separator: "\n").last!), to: file)
            let result = reader.refresh()
            XCTAssertEqual(result.context.value?.latestResponse.total, 250)
            XCTAssertEqual(result.agentName, "Agent Name")
        }
    }
    func testUndeclaredEmbeddedMetadataStillFailsClosed() throws {
        try withFixture { root, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNotNil(reader.refresh().context.value)
            try append(#"{"type":"session_meta","payload":{"id":"unrelated","cli_version":"0.153.4"}}"#, to: file)
            try append(String(source.split(separator: "\n").last!), to: file)
            XCTAssertEqual(reader.refresh().context.unavailableReason, .unsupportedSchema)
        }
    }
    func testSeparateReadersKeepDifferentModelsAndWindows() throws {
        try withFixture { root, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            try source.replacingOccurrences(of: "\"model_context_window\":1000", with: "\"model_context_window\":100000")
                .write(to: file, atomically: true, encoding: .utf8)
            let agentFile = root.appendingPathComponent("agent.jsonl")
            let agentData = source.replacingOccurrences(of: "fixture-root", with: "fixture-agent")
                .replacingOccurrences(of: "\"cli_version\":\"0.153.4\"", with: "\"cli_version\":\"0.153.4\",\"agent_nickname\":\"Darwin\"")
                .replacingOccurrences(of: "fixture-model", with: "agent-model")
                .replacingOccurrences(of: "\"model_context_window\":1000", with: "\"model_context_window\":200000")
                .replacingOccurrences(of: "\"input_tokens\":200", with: "\"input_tokens\":55950")
                .replacingOccurrences(of: "\"total_tokens\":250", with: "\"total_tokens\":56000")
                .replacingOccurrences(of: "\"input_tokens\":8000", with: "\"input_tokens\":98000")
                .replacingOccurrences(of: "\"total_tokens\":10000", with: "\"total_tokens\":100000")
            try agentData.write(to: agentFile, atomically: true, encoding: .utf8)
            let parent = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root").refresh()
            let agent = try SessionLogReader(root: root, path: agentFile.path, threadID: "fixture-agent").refresh()
            XCTAssertEqual(parent.model, "fixture-model")
            XCTAssertEqual(agent.model, "agent-model")
            XCTAssertEqual(agent.agentName, "Darwin")
            XCTAssertEqual(parent.context.value?.estimatedRemainingPercentage, 100)
            XCTAssertEqual(agent.context.value?.estimatedRemainingPercentage, 77)
            XCTAssertEqual(agent.context.value?.latestResponse.total, 56_000)
        }
    }
    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n").utf8))
    }
    func testCompactionClearsOldContextUntilTheNextCounterThenAcceptsDecrease() throws {
        try withFixture { root, file in
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertEqual(reader.refresh().context.value?.latestResponse.total, 250)
            try append(#"{"type":"compacted","payload":{"message":"PRIVATE_SUMMARY"}}"#, to: file)
            let pending = reader.refresh()
            XCTAssertEqual(pending.context.unavailableReason, .updatingContext)
            XCTAssertFalse(String(describing: pending).contains("PRIVATE_SUMMARY"))
            let source = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first { $0.contains("token_count") }!
            let next = source.replacingOccurrences(of: "\"input_tokens\":200", with: "\"input_tokens\":100")
                .replacingOccurrences(of: "\"total_tokens\":250", with: "\"total_tokens\":150")
                .replacingOccurrences(of: "\"cached_input_tokens\":150", with: "\"cached_input_tokens\":50")
            try append(next, to: file)
            let result = reader.refresh()
            XCTAssertEqual(result.context.value?.latestResponse.total, 150)
            XCTAssertEqual(result.context.value?.cumulative.total, 10_000)
        }
    }
    func testModelChangeWaitsForCountersWithNewWindow() throws {
        try withFixture { root, file in
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNotNil(reader.refresh().context.value)
            let source = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first { $0.contains("token_count") }!
            try append(#"{"type":"turn_context","payload":{"model":"new-model"}}"#, to: file)
            let pending = reader.refresh()
            XCTAssertEqual(pending.model, "new-model")
            XCTAssertEqual(pending.context.unavailableReason, .updatingContext)
            try append(source.replacingOccurrences(of: "\"model_context_window\":1000", with: "\"model_context_window\":200000"), to: file)
            XCTAssertEqual(reader.refresh().context.value?.modelContextWindow, 200_000)
        }
    }
    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "counters-0.153.4", withExtension: "jsonl"))
        let file = root.appendingPathComponent("task.jsonl")
        try FileManager.default.copyItem(at: source, to: file)
        try body(root, file)
    }
    func testExactCountersRemainSeparateAndDoNotRetainContent() throws {
        try withFixture { root, file in
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            let result = reader.refresh()
            XCTAssertEqual(result.context.value?.latestResponse.total, 250)
            XCTAssertEqual(result.context.value?.cumulative.total, 10_000)
            XCTAssertEqual(result.model, "fixture-model")
            XCTAssertFalse(result.occupancyVerified)
            XCTAssertFalse(String(describing: result).contains("PRIVATE_"))
            let offset = reader.offset
            XCTAssertEqual(reader.refresh().context.value, result.context.value)
            XCTAssertEqual(reader.offset, offset)
        }
    }
    func testTruncatedTailRetriesAfterCompletion() throws {
        try withFixture { root, file in
            let data = try Data(contentsOf: file)
            try data.dropLast(3).write(to: file)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNil(reader.refresh().context.value)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: data.suffix(3)); try handle.close()
            XCTAssertEqual(reader.refresh().context.value?.latestResponse.total, 250)
        }
    }
    func testInvalidCounterAndFutureSchemaFailClosed() throws {
        try withFixture { root, file in
            var text = try String(contentsOf: file, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"total_tokens\":250", with: "\"total_tokens\":249")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertEqual(reader.refresh().context.unavailableReason, .unsupportedSchema)
        }
        try withFixture { root, file in
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "other")
            XCTAssertEqual(reader.refresh().context.unavailableReason, .unsupportedSchema)
        }
    }
    func testPathEscapesSymlinksAndNonRegularFilesRejected() throws {
        try withFixture { root, file in
            XCTAssertThrowsError(try SessionLogReader(root: root, path: "/etc/hosts", threadID: "x"))
            let link = root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
            XCTAssertThrowsError(try SessionLogReader(root: root, path: link.path, threadID: "x"))
            XCTAssertThrowsError(try SessionLogReader(root: root, path: root.path, threadID: "x"))
            let fifo = root.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try SessionLogReader(root: root, path: fifo.path, threadID: "x"))
        }
    }
    func testRotationInvalidatesAndOversizedRecordsAreBounded() throws {
        try withFixture { root, file in
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root")
            XCTAssertNotNil(reader.refresh().context.value)
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(reader.refresh().context.unavailableReason, .missingSession)
        }
        try withFixture { root, file in
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 120, count: 3000)); try handle.write(contentsOf: Data([10])); try handle.close()
            let reader = try SessionLogReader(root: root, path: file.path, threadID: "fixture-root", maximumLineBytes: 1024, byteBudget: 2048)
            var result = reader.refresh()
            XCTAssertTrue(result.moreData)
            result = reader.refresh()
            XCTAssertEqual(result.context.unavailableReason, .unsupportedSchema)
            XCTAssertLessThanOrEqual(reader.bufferedBytes, 1024)
        }
    }
}
