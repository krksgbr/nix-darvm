import ArgumentParser
import Foundation

// MARK: - ConfigGet

struct ConfigGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-get",
        abstract: "Read a value from config.toml"
    )

    @Argument(help: "Config key to read (e.g. flake)")
    var key: String

    func run() throws {
        let config = try DVMConfig.load()
        switch key {
        case "flake":
            guard let flake = config.flake else { throw ExitCode(1) }
            print(flake)

        default:
            throw ExitCode(1)
        }
    }
}

// MARK: - ReloadCapabilities

struct ReloadCapabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload-capabilities",
        abstract: "Hot-reload the host action bridge's capabilities manifest"
    )

    @Option(name: .long, help: "Path to capabilities.json manifest (must be in /nix/store/)")
    var path: String

    func run() throws {
        if let error = ControlSocket.sendReloadCapabilities(path: path) {
            fputs("Error: \(error)\n", stderr)
            throw ExitCode(1)
        }
    }
}

// MARK: - Stop

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Gracefully shut down the VM"
    )

    func run() async throws {
        let agentClient = AgentClient()
        do {
            print("Shutting down VM...")
            _ = try await agentClient.exec(
                command: ["sudo", "shutdown", "-h", "now"]
            )
        } catch {
            // Fallback: try control socket to check if running at all
            if case .failure(.socketNotFound) = ControlSocket.send(.status) {
                print("VM not running.")
            } else {
                print("Shutdown command failed: \(error)")
            }
        }
    }
}

// MARK: - Credential Resolution (exec/ssh time)

/// Discover, parse, resolve, and push credentials to the sidecar.
/// Returns env vars to inject into the guest session (placeholder values).
/// Returns empty dict if no manifest is found.
/// Discover the credential manifest path based on the priority chain:
/// `--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd.
/// Returns nil if no manifest is found (CWD fallback only).
/// Explicit sources (flag, env var) that point to missing files throw.
func discoverManifestPath(
    credentialsFlag: String?,
    cwd: String
) throws -> String? {
    if let flag = credentialsFlag {
        // Explicit flag — resolve relative to host cwd, fail loudly if missing
        let resolved = URL(fileURLWithPath: flag, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SecretConfigError.manifestNotFound(resolved)
        }
        return resolved
    }
    if let envPath = ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] {
        // Explicit env var — empty = error, missing file = error
        guard !envPath.isEmpty else {
            throw SecretConfigError.manifestNotFound(
                "DVM_CREDENTIALS is set but empty")
        }
        let resolved = URL(fileURLWithPath: envPath, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SecretConfigError.manifestNotFound(resolved)
        }
        return resolved
    }
    // CWD discovery — no walking, silent skip if not found
    let cwdManifest = (cwd as NSString).appendingPathComponent(".dvm/credentials.toml")
    return FileManager.default.fileExists(atPath: cwdManifest) ? cwdManifest : nil
}

private func resolveAndPushCredentials(
    credentialsFlag: String?,
    cwd: String
) throws -> [String: String] {
    // Explicit sources (--credentials flag, DVM_CREDENTIALS env var) fail hard —
    // the user asked for credentials and they must resolve.
    // CWD auto-discovery (.dvm/credentials.toml) warns and continues —
    // the user didn't ask for credentials, so don't block their command.
    let explicit =
        credentialsFlag != nil
        || ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] != nil

    guard
        let path = try discoverManifestPath(
            credentialsFlag: credentialsFlag, cwd: cwd)
    else {
        return [:]  // no manifest, no credentials — session runs without injection
    }

    do {
        let manifest = try CredentialManifest.load(from: path)
        let hostKey = try HostKey.loadOrCreate()
        let secrets = try manifest.resolve(hostKey: hostKey)

        // Only proxy secrets need MITM interception via the sidecar.
        let proxySecrets = secrets.filter { $0.mode == .proxy }

        // Always push — even empty secrets list clears previous mappings for this project.
        if let error = ControlSocket.sendLoadCredentials(
            projectName: manifest.project, secrets: proxySecrets) {
            throw CredentialPushError(detail: error)
        }

        // Build env vars for guest injection:
        // - proxy secrets: ENV_VAR=placeholder (sidecar substitutes real value)
        // - passthrough secrets: ENV_VAR=realValue (injected directly)
        var env: [String: String] = [:]
        for secret in secrets {
            env[secret.name] = secret.placeholder
        }
        return env
    } catch {
        if explicit { throw error }
        fputs("Warning: credential resolution failed, running without injection: \(error)\n", stderr)
        return [:]
    }
}

/// Error pushing credentials to the sidecar via the control socket.
struct CredentialPushError: Error, CustomStringConvertible {
    let detail: String
    var description: String { "Failed to push credentials to proxy: \(detail)" }
}

// MARK: - Exec

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the VM"
    )

    @Flag(name: .shortAndLong, help: "Allocate a TTY")
    var tty: Bool = false

    @Option(name: .long, help: "Path to credentials.toml manifest")
    var credentials: String?

    @Argument(help: "Command and arguments to execute")
    var command: [String] = []

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        guard !command.isEmpty else {
            throw CleanExit.helpRequest(self)
        }

        // Resolve credentials and push to sidecar
        let credentialEnv = try resolveAndPushCredentials(
            credentialsFlag: credentials, cwd: cwd)

        let exitCode: Int32
        if tty {
            exitCode = try await agentClient.execInteractive(
                command: command,
                cwd: cwd,
                tty: true,
                env: credentialEnv
            )
        } else {
            exitCode = try await agentClient.exec(
                command: command,
                cwd: cwd,
                env: credentialEnv
            )
        }

        throw ExitCode(exitCode)
    }
}

// MARK: - SSH (interactive shell)

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open an interactive shell session to the VM"
    )

    @Option(name: .long, help: "Path to credentials.toml manifest")
    var credentials: String?

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        // Resolve credentials and push to sidecar
        let credentialEnv = try resolveAndPushCredentials(
            credentialsFlag: credentials, cwd: cwd)

        let exitCode = try await agentClient.execInteractive(
            command: ["/bin/zsh", "-l"],
            cwd: cwd,
            tty: true,
            env: credentialEnv
        )
        throw ExitCode(exitCode)
    }
}

// MARK: - Status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show VM status"
    )

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        if json {
            try outputJSON()
        } else {
            try outputHuman()
        }
    }

    private func outputJSON() throws {
        var result: [String: Any] = ["running": false]

        switch ControlSocket.send(.status) {
        case .success(.status(let payload)):
            populateStatusJSON(&result, from: payload)
            addGuestHealthJSON(&result, status: payload)

        case .failure:
            break

        default:
            break
        }

        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard let output = String(data: data, encoding: .utf8) else {
            throw CleanError.message("status response was not valid UTF-8")
        }
        print(output)

        if result["running"] as? Bool != true {
            throw ExitCode(1)
        }
    }

    private func populateStatusJSON(
        _ result: inout [String: Any],
        from payload: ControlSocketStatusPayload
    ) {
        result["running"] = payload.running
        if let phase = payload.phase { result["phase"] = phase }
        if let ipAddress = payload.ipAddress { result["ip"] = ipAddress }
        if let runId = payload.runId { result["run_id"] = runId }
        if let phaseError = payload.phaseError { result["error"] = phaseError }
    }

    private func addGuestHealthJSON(
        _ result: inout [String: Any],
        status payload: ControlSocketStatusPayload
    ) {
        guard payload.running, payload.phase == VMPhase.running.rawValue else {
            return
        }
        guard case .success(.guestHealth(let health)) = ControlSocket.send(.guestHealth, timeout: 5)
        else {
            return
        }
        result["mounts"] = health.mounts
        result["activation"] = health.activation
        result["services"] = health.services
    }

    private func outputHuman() throws {
        let statusResult = ControlSocket.send(.status)
        switch statusResult {
        case .success(.status(let payload)):
            guard payload.running else { try printStoppedStatus(payload) }
            print(statusSummaryLine(payload))
            if let runId = payload.runId {
                print("  Run:        \(runId)")
            }

            if payload.phase == VMPhase.running.rawValue {
                printGuestHealthSummary()
            }

        default:
            try throwStatusFailure(statusResult)
        }
    }
}
