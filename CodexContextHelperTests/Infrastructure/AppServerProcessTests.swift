import XCTest
@testable import CodexContextHelper

final class AppServerProcessTests: XCTestCase {
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
        XCTAssertEqual(Set(environment.keys), ["HOME", "PATH", "LANG", "TMPDIR"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
    }
}
