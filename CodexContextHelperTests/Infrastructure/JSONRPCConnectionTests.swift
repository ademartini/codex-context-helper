import XCTest
@testable import CodexContextHelper

final class JSONRPCConnectionTests: XCTestCase, @unchecked Sendable {
    private let handshake = """
    import sys, json, time, signal
    def emit(value):
        print(json.dumps(value), flush=True)
    init = json.loads(sys.stdin.readline())
    assert init['method'] == 'initialize'
    assert init['params']['capabilities']['experimentalApi'] is True
    emit({'id':init['id'], 'result':{}})
    ready = json.loads(sys.stdin.readline())
    assert ready['method'] == 'initialized'
    """

    private func process(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script]
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        return process
    }

    func testHandshakeAndFragmentedResponseDoNotWaitForFullReadBuffer() async throws {
        let child = process(handshake + "\n" + """
        request = json.loads(sys.stdin.readline())
        response = json.dumps({'id':request['id'], 'result':{'data':[], 'nextCursor':None}}) + chr(10)
        for character in response:
            sys.stdout.write(character)
            sys.stdout.flush()
        time.sleep(30)
        """)
        let connection = JSONRPCConnection(process: child, requestTimeout: .seconds(2))
        try await connection.start()
        let response = try await connection.request(method: "thread/list", params: .object(["useStateDbOnly": .bool(true)]))
        XCTAssertEqual(response["data"], .array([]))
        await connection.close()
        XCTAssertFalse(child.isRunning)
        let health = await connection.health
        XCTAssertEqual(health, .stopped)
    }

    func testInterleavedNotificationsAndOutOfOrderResponsesCorrelateIDs() async throws {
        let child = process(handshake + "\n" + """
        requests = [json.loads(sys.stdin.readline()), json.loads(sys.stdin.readline())]
        emit({'method':'thread/status/changed','params':{'private':'PRIVATE_NOTIFICATION_SENTINEL'}})
        for request in reversed(requests):
            emit({'id':request['id'], 'result':{'method':request['method']}})
        time.sleep(30)
        """)
        let connection = JSONRPCConnection(process: child, requestTimeout: .seconds(2))
        try await connection.start()
        async let quotas = connection.request(method: "account/rateLimits/read")
        async let usage = connection.request(method: "account/usage/read")
        let results = try await (quotas, usage)
        XCTAssertEqual(results.0["method"], .string("account/rateLimits/read"))
        XCTAssertEqual(results.1["method"], .string("account/usage/read"))
        await connection.close()
    }

    func testMutationsAndHydrationRejectedBeforeChildReceivesThem() async throws {
        let child = process(handshake + "\n" + """
        request = json.loads(sys.stdin.readline())
        emit({'id':request['id'], 'result':{'method':request['method']}})
        time.sleep(30)
        """)
        let connection = JSONRPCConnection(process: child)
        try await connection.start()
        for method in ["turn/start", "thread/resume", "account/rateLimits/reset", "initialize", "initialized"] {
            do { _ = try await connection.request(method: method); XCTFail("Mutation was accepted") }
            catch { XCTAssertEqual(error as? AppServerError, .forbiddenMethod) }
        }
        for params: JSONValue in [.object(["threadId": .string("root"), "includeTurns": .bool(true)]), .object(["threadId": .string("root")])] {
            do { _ = try await connection.request(method: "thread/read", params: params); XCTFail("Content read was accepted") }
            catch { XCTAssertEqual(error as? AppServerError, .invalidParameters) }
        }
        XCTAssertThrowsError(try JSONRPCConnection.validate(method: "account/read", params: .object(["refreshToken": .bool(true)])))
        XCTAssertThrowsError(try JSONRPCConnection.validate(method: "thread/list", params: .object([:])))
        let result = try await connection.request(method: "account/usage/read")
        XCTAssertEqual(result["method"], .string("account/usage/read"))
        await connection.close()
    }

    func testTimeoutKillsUncooperativeChildAndResumesEveryPendingRequest() async throws {
        let child = process(handshake + "\n" + """
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(30)
        """)
        let connection = JSONRPCConnection(process: child, requestTimeout: .milliseconds(300))
        try await connection.start()
        async let first = requestError(connection, method: "account/usage/read")
        async let second = requestError(connection, method: "account/rateLimits/read")
        let errors = await (first, second)
        XCTAssertEqual(errors.0, .timeout)
        XCTAssertEqual(errors.1, .timeout)
        await connection.close()
        XCTAssertFalse(child.isRunning)
    }

    func testMalformedAndOversizedFramesFailWithoutRawDiagnostics() async throws {
        let cases: [(String, AppServerError)] = [
            ("print('PRIVATE_INVALID_JSON', flush=True)", .malformedResponse),
            ("sys.stdout.write('x' * 2049); sys.stdout.flush()", .frameTooLarge)
        ]
        for (body, expected) in cases {
            let child = process(handshake + "\nrequest = sys.stdin.readline()\n" + body + "\ntime.sleep(30)\n")
            let connection = JSONRPCConnection(process: child, requestTimeout: .seconds(2), maximumFrameBytes: 1024)
            try await connection.start()
            let error = await requestError(connection, method: "account/usage/read")
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains("PRIVATE"))
            await connection.close()
            XCTAssertFalse(child.isRunning)
        }
    }

    func testUnsupportedMethodAndAuthenticationErrorsAreSanitized() async throws {
        for (code, expected): (Int, AppServerError) in [(-32601, .unsupportedMethod), (401, .signedOut), (-32000, .serverFailure)] {
            let child = process(handshake + "\n" + """
            request = json.loads(sys.stdin.readline())
            emit({'id':request['id'], 'error':{'code':\(code), 'message':'PRIVATE_SERVER_ERROR', 'data':{'secret':'PRIVATE_TOKEN'}}})
            time.sleep(30)
            """)
            let connection = JSONRPCConnection(process: child)
            try await connection.start()
            let error = await requestError(connection, method: "account/usage/read")
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains("PRIVATE"))
            await connection.close()
        }
    }

    func testChildExitResumesPendingRequest() async throws {
        let child = process(handshake + "\nsys.stdin.readline()\nsys.exit(0)\n")
        let connection = JSONRPCConnection(process: child, requestTimeout: .seconds(2))
        try await connection.start()
        let error = await requestError(connection, method: "account/usage/read")
        XCTAssertEqual(error, .disconnected)
        await connection.close()
        XCTAssertFalse(child.isRunning)
    }

    func testClosedInputPipeFailsWithoutSIGPIPEOrBlockingTimeout() async throws {
        let child = process(handshake + "\n" + """
        sys.stdin.close()
        import os
        os.close(0)
        emit({'method':'ready'})
        time.sleep(30)
        """)
        let connection = JSONRPCConnection(process: child, requestTimeout: .milliseconds(500))
        try await connection.start()
        try await Task.sleep(for: .milliseconds(50))
        let error = await requestError(connection, method: "account/usage/read")
        XCTAssertTrue(error == .disconnected || error == .timeout)
        await connection.close()
        XCTAssertFalse(child.isRunning)
    }

    func testIntegerMicrosNeverPassThroughFloatingPoint() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"amount\":9007199254740993}".utf8))
        XCTAssertEqual(value["amount"]?.integer, 9_007_199_254_740_993)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip, value)
    }

    private func requestError(_ connection: JSONRPCConnection, method: String) async -> AppServerError? {
        do { _ = try await connection.request(method: method); return nil }
        catch { return error as? AppServerError }
    }
}
