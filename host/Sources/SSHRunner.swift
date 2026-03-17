import Foundation

/// Runs SSH commands using password auth via the SSH_ASKPASS mechanism.
/// Follows Lume's approach: creates a temp script that echoes the password,
/// sets SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force.
struct SSHRunner {
    let host: GuestIP
    let user: String
    let password: String
    let port: UInt16

    init(host: GuestIP, user: String = "admin", password: String = "admin", port: UInt16 = 22) {
        self.host = host
        self.user = user
        self.password = password
        self.port = port
    }

    /// Run an SSH command, inheriting the caller's stdin/stdout/stderr.
    /// Returns the remote process exit code. Throws on local failures.
    ///
    /// For interactive sessions (tty=true), uses `execvp` to replace the current
    /// process with SSH. This is necessary because Swift's `Process` (posix_spawn)
    /// creates a new process group that detaches from the controlling terminal,
    /// which breaks interactive PTY sessions. Since there's nothing to do after
    /// SSH exits, `execvp` is the correct approach — the OS cleans up on exit.
    func run(command: [String], tty: Bool = false) throws -> Int32 {
        let effectiveTTY = tty || command.isEmpty

        // Interactive sessions: exec into SSH directly for proper terminal handling
        if effectiveTTY {
            try execSSH(command: command, tty: true)
        }

        // Non-interactive: use Process (safe, no terminal needed)
        let askpassPath = try createAskpassScript()
        defer { try? FileManager.default.removeItem(atPath: askpassPath) }

        let process = try launchSSH(
            args: buildArgs(command: command, tty: false),
            askpassPath: askpassPath,
            stdin: FileHandle.standardInput,
            stdout: FileHandle.standardOutput,
            stderr: FileHandle.standardError
        )
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Run an SSH command silently (discard stdout/stderr).
    /// Returns the remote exit code. Throws on local failures (askpass, process launch).
    func runSilent(command: [String]) throws -> Int32 {
        let askpassPath = try createAskpassScript()
        defer { try? FileManager.default.removeItem(atPath: askpassPath) }

        let process = try launchSSH(
            args: buildArgs(command: command, tty: false),
            askpassPath: askpassPath,
            stdin: FileHandle.nullDevice,
            stdout: FileHandle.nullDevice,
            stderr: FileHandle.nullDevice
        )
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Run an SSH command, capturing stdout. Stderr is discarded.
    /// Returns stdout trimmed, or nil on non-zero exit.
    func runCaptureOutput(command: [String]) throws -> String? {
        let askpassPath = try createAskpassScript()
        defer { try? FileManager.default.removeItem(atPath: askpassPath) }

        let stdoutPipe = Pipe()
        let process = try launchSSH(
            args: buildArgs(command: command, tty: false),
            askpassPath: askpassPath,
            stdin: FileHandle.nullDevice,
            stdout: stdoutPipe.fileHandleForWriting,
            stderr: FileHandle.nullDevice
        )
        stdoutPipe.fileHandleForWriting.closeFile()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Result of a capturing SSH command.
    struct CapturedResult {
        let exitCode: Int32
        let stderr: String
    }

    /// Run an SSH command, capturing stderr. Stdout is discarded.
    /// On non-zero exit, stderr contains the guest's error output for diagnosis.
    func runCapturing(command: [String]) throws -> CapturedResult {
        let askpassPath = try createAskpassScript()
        defer { try? FileManager.default.removeItem(atPath: askpassPath) }

        let stderrPipe = Pipe()
        let process = try launchSSH(
            args: buildArgs(command: command, tty: false),
            askpassPath: askpassPath,
            stdin: FileHandle.nullDevice,
            stdout: FileHandle.nullDevice,
            stderr: stderrPipe.fileHandleForWriting
        )
        // Close our copy of the write end so read doesn't hang
        stderrPipe.fileHandleForWriting.closeFile()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CapturedResult(exitCode: process.terminationStatus, stderr: stderrText)
    }

    /// Launch an SSH command in the background. Returns the Process so the caller
    /// can terminate it later. Stdout is forwarded to the given FileHandle.
    func launchBackground(command: [String], stdout: FileHandle) throws -> Process {
        let askpassPath = try createAskpassScript()
        let process = try launchSSH(
            args: buildArgs(command: command, tty: false),
            askpassPath: askpassPath,
            stdin: FileHandle.nullDevice,
            stdout: stdout,
            stderr: FileHandle.nullDevice
        )
        return process
    }

    // MARK: - Private

    private func buildArgs(command: [String], tty: Bool) -> [String] {
        var args = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "PubkeyAuthentication=no",
        ]
        if port != 22 { args += ["-p", "\(port)"] }
        if tty { args.append("-t") }
        args += ["\(user)@\(host.rawValue)"]
        args += command
        return args
    }

    /// Replace the current process with SSH via execvp. Never returns on success.
    /// The askpass script in /tmp is cleaned up by the OS on process exit.
    private func execSSH(command: [String], tty: Bool) throws -> Never {
        let askpassPath = try createAskpassScript()
        let args = buildArgs(command: command, tty: tty)

        // Set environment for ASKPASS
        setenv("SSH_ASKPASS", askpassPath, 1)
        setenv("SSH_ASKPASS_REQUIRE", "force", 1)
        setenv("DISPLAY", ":0", 1)

        // Build null-terminated C string arrays for execvp
        let cPath = "/usr/bin/ssh"
        let cArgs = [cPath] + args
        let cArgPtrs = cArgs.map { strdup($0)! } + [nil]

        execvp(cPath, cArgPtrs)

        // execvp only returns on failure
        let err = String(cString: strerror(errno))
        fputs("exec ssh failed: \(err)\n", stderr)
        exit(1)
    }

    private func launchSSH(
        args: [String],
        askpassPath: String,
        stdin: FileHandle,
        stdout: FileHandle,
        stderr: FileHandle
    ) throws -> Process {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpassPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        return process
    }

    private func createAskpassScript() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("dvm-askpass-\(UUID().uuidString).sh").path

        // Escape single quotes in password
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let content = "#!/bin/sh\necho '\(escaped)'\n"

        guard FileManager.default.createFile(
            atPath: scriptPath,
            contents: content.data(using: .utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw SSHError.askpassFailed
        }

        return scriptPath
    }
}

enum SSHError: Error, CustomStringConvertible {
    case askpassFailed

    var description: String {
        switch self {
        case .askpassFailed: return "Failed to create SSH_ASKPASS script"
        }
    }
}
