import XCTest
@testable import CodexContextHelper

final class AppServerProcessTests: XCTestCase {
    func testVersionIdentityAcceptsPatchMinorAndPrereleaseWithoutExactReleaseGate() throws {
        for version in ["0.153.4", "0.153.5", "0.154.0", "1.0.0", "0.155.0-alpha.2", "0.155.0-alpha-2+fixture.03"] {
            XCTAssertEqual(try AppServerProcess.parseVersionOutput("codex-cli \(version)\n"), version)
            let approved = ApprovedExecutable(path: "/usr/bin/true", identity: try AppServerProcess.identity(at: "/usr/bin/true"), version: version)
            let process = try AppServerProcess.make(approved: approved)
            XCTAssertEqual(process.arguments, ["app-server", "-c", "analytics.enabled=false"])
            XCTAssertEqual(process.environment?["CODEX_HOME"], CodexDataLocation.home.path)
            XCTAssertFalse(process.isRunning)
        }
    }

    func testVersionIdentityRejectsOtherToolsMalformedVersionsAndUnboundedOutput() {
        for output in ["", "0.153.4", "another-cli 0.153.4", "codex-cli 0.153", "codex-cli 01.153.4",
                       "codex-cli 0.153.4-alpha..1", "codex-cli 0.153.4-01", "codex-cli 0.153.4+",
                       "codex-cli 0.153.4\nother output", "codex-cli 0.153.4 trailing", "codex-cli " + String(repeating: "1", count: 300)] {
            XCTAssertThrowsError(try AppServerProcess.parseVersionOutput(output)) { error in
                XCTAssertEqual(error as? ExecutableError, .unsupportedVersion)
            }
        }
    }

    func testUnapprovedAndChangedExecutableNeverStarts() throws {
        let approval = ApprovedExecutable(path: "/usr/bin/true", identity: "replaced", version: "0.153.4")
        XCTAssertThrowsError(try AppServerProcess.make(approved: approval))
    }

    func testWritableExecutableRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.path)
        XCTAssertThrowsError(try AppServerProcess.identity(at: url.path))
    }

    func testNonCodexNativeBinaryCannotBeApproved() async {
        do {
            _ = try await AppServerProcess.approve(path: "/usr/bin/true")
            XCTFail("A native executable with the wrong version must not be approved")
        } catch { XCTAssertEqual(error as? ExecutableError, .unsupportedVersion) }
    }

    func testIdentityChangesWhenNativeFileIsReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: url.path)
        let first = try AppServerProcess.identity(at: url.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(atPath: "/usr/bin/false", toPath: url.path)
        XCTAssertNotEqual(first, try AppServerProcess.identity(at: url.path))
    }

    func testIdentityRejectsDirectoryAndScript() {
        XCTAssertThrowsError(try AppServerProcess.identity(at: "/tmp"))
        XCTAssertThrowsError(try AppServerProcess.identity(at: "/does/not/exist"))
    }

    func testNativeIdentityStableAndEnvironmentMinimal() throws {
        let identity = try AppServerProcess.identity(at: "/usr/bin/true")
        XCTAssertEqual(identity, try AppServerProcess.identity(at: "/usr/bin/true"))
        let environment = AppServerProcess.environment(launcherPATH: "/usr/bin:/bin")
        XCTAssertEqual(Set(environment.keys), ["HOME", "PATH", "LANG", "TMPDIR", "CODEX_HOME"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertEqual(environment["CODEX_HOME"], CodexDataLocation.home.path)
    }
}
