import Foundation
import CryptoKit
import Darwin

enum ExecutableError: Error, Equatable {
    case invalidFile, unsafePermissions, unsupportedExecutable, changed, unsupportedVersion, launchFailed, timedOut
}

/// Executes only approved native Codex binaries, avoiding untracked script/interpreter dependencies.
/// npm launchers are resolved to their already-installed native binary before approval.
enum AppServerProcess {
    static let supportedVersion = "0.153.4"

    static func environment(launcherPATH: String?) -> [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "PATH": launcherPATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
         "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }

    static func identity(at path: String) throws -> String {
        guard path.hasPrefix("/") else { throw ExecutableError.invalidFile }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ExecutableError.invalidFile }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ExecutableError.invalidFile }
        guard before.st_uid == getuid() || before.st_uid == 0,
              before.st_mode & 0o022 == 0, before.st_mode & 0o111 != 0 else { throw ExecutableError.unsafePermissions }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var first = true
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw ExecutableError.invalidFile }
            if count == 0 { break }
            if first {
                let magic = Array(buffer.prefix(4))
                guard [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                       [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf]].contains(magic) else {
                    throw ExecutableError.unsupportedExecutable
                }
                first = false
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard !first else { throw ExecutableError.invalidFile }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ExecutableError.changed }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(before.st_dev):\(before.st_ino):\(before.st_size):\(digest)"
    }

    static func make(approved: ApprovedExecutable) throws -> Process {
        guard approved.version == supportedVersion else { throw ExecutableError.unsupportedVersion }
        guard try identity(at: approved.path) == approved.identity else { throw ExecutableError.changed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: approved.path)
        process.arguments = ["app-server", "--stdio", "-c", "analytics.enabled=false"]
        process.environment = environment(launcherPATH: approved.launcherPATH)
        process.standardInput = Pipe(); process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// This is called only by the explicit approval control, never during discovery.
    static func approve(path: String, launcherPATH: String? = nil) async throws -> ApprovedExecutable {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return try await Task.detached(priority: .userInitiated) {
            let fingerprint = try identity(at: canonical)
            let output = try runBounded(path: canonical, arguments: ["--version"], launcherPATH: launcherPATH)
            guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli \(supportedVersion)" else {
                throw ExecutableError.unsupportedVersion
            }
            guard try identity(at: canonical) == fingerprint else { throw ExecutableError.changed }
            return ApprovedExecutable(path: canonical, identity: fingerprint, version: supportedVersion, launcherPATH: launcherPATH)
        }.value
    }

    static func discover() async -> String? {
        await Task.detached(priority: .utility) {
            // GUI login-shell PATH can prefer an obsolete Homebrew install over an audited npm install.
            // Inspect only package version metadata; executing --version still requires the approval action.
            let manager = FileManager.default
            let versions = manager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
            if let directories = try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
                let ordered = directories.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                for directory in ordered.prefix(20) {
                    let package = directory.appendingPathComponent("lib/node_modules/@openai/codex")
                    struct PackageVersion: Decodable { let version: String }
                    guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")), data.count < 64 * 1024,
                          let metadata = try? JSONDecoder().decode(PackageVersion.self, from: data), metadata.version == supportedVersion else { continue }
                    if let candidate = nativePackageBinary(package) { return candidate }
                }
            }
            // Fixed command only; no user text is interpolated into the login shell.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(shell),
                  let output = try? runBounded(path: shell, arguments: ["-lc", "command -v codex"], launcherPATH: nil),
                  let path = output.split(separator: "\n").last.map(String.init), path.hasPrefix("/") else { return nil }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if (try? identity(at: canonical.path)) != nil { return canonical.path }
            // Resolve the official npm layout without running its JavaScript launcher or downloading anything.
            let package = canonical.deletingLastPathComponent().deletingLastPathComponent()
            return nativePackageBinary(package)
        }.value
    }

    private static func nativePackageBinary(_ package: URL) -> String? {
        #if arch(arm64)
        let target = "aarch64-apple-darwin", packageName = "codex-darwin-arm64"
        #else
        let target = "x86_64-apple-darwin", packageName = "codex-darwin-x64"
        #endif
        for relative in ["node_modules/@openai/\(packageName)/vendor/\(target)/bin/codex", "vendor/\(target)/bin/codex"] {
            let candidate = package.appendingPathComponent(relative).resolvingSymlinksInPath().path
            if (try? identity(at: candidate)) != nil { return candidate }
        }
        return nil
    }

    private static func runBounded(path: String, arguments: [String], launcherPATH: String?) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = environment(launcherPATH: launcherPATH)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ExecutableError.launchFailed }
        let handle = pipe.fileHandleForReading
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? handle.close()
        }
        let deadline = Date().addingTimeInterval(5)
        var output = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        var reachedEOF = false
        while Date() < deadline {
            let count = read(fd, &bytes, bytes.count)
            if count == 0 { reachedEOF = true; break }
            if count > 0 {
                guard output.count + count <= 16 * 1024 else { throw ExecutableError.launchFailed }
                output.append(contentsOf: bytes.prefix(count))
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw ExecutableError.launchFailed
            }
            if count < 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard reachedEOF else { throw ExecutableError.timedOut }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { throw ExecutableError.timedOut }
        guard process.terminationStatus == 0 else { throw ExecutableError.launchFailed }
        guard let text = String(data: output, encoding: .utf8) else { throw ExecutableError.launchFailed }
        return text
    }
}
