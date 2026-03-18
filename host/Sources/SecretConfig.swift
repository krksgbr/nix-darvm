import Foundation
import Security
import TOML

// MARK: - Secret Configuration Types

/// How a secret value is injected into HTTP requests.
enum InjectMode: Equatable, Sendable {
    /// `Authorization: Bearer <value>`
    case bearer
    /// `Authorization: Basic <value>`
    case basic
    /// Custom header: `<name>: <value>`
    case header(name: String)
}

/// Where a secret's real value comes from on the host.
enum SecretProvider: Equatable, Sendable {
    /// Read from host environment variable.
    case env(name: String)
    /// Read from macOS Keychain.
    case keychain(service: String, account: String)
    /// Run a command and capture stdout.
    case command(argv: [String])
}

/// A single secret declaration from `.dvm/credentials.toml`.
struct SecretRule: Sendable {
    let name: String
    let hosts: [String]
    let inject: InjectMode
    let provider: SecretProvider
}

/// A secret after host-side provider resolution.
/// The `value` is the real credential — lives in memory only, never in guest.
struct ResolvedSecret: Sendable {
    let name: String
    let placeholder: String
    let value: String
    let hosts: [String]
    let inject: InjectMode
}

/// Parsed per-project credential manifest.
struct CredentialManifest: Sendable {
    let version: Int
    let secrets: [SecretRule]
}

// MARK: - TOML Parsing

/// Raw Codable shapes for TOMLDecoder. Converted to typed domain objects after decode.
private struct RawManifest: Codable {
    let version: Int
    let secrets: [RawSecret]?
}

private struct RawSecret: Codable {
    let name: String
    let hosts: [String]
    let inject: RawInject
    let provider: RawProvider
}

/// Inject is either a bare string ("bearer", "basic") or an inline table.
private enum RawInject: Codable {
    case shorthand(String)
    case table(type: String, name: String?)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .shorthand(s)
            return
        }
        let tbl = try InjectTable(from: decoder)
        self = .table(type: tbl.type, name: tbl.name)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .shorthand(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .table(let type, let name):
            try InjectTable(type: type, name: name).encode(to: encoder)
        }
    }

    private struct InjectTable: Codable {
        let type: String
        let name: String?
    }
}

private struct RawProvider: Codable {
    let type: String
    let name: String?      // env
    let service: String?   // keychain
    let account: String?   // keychain
    let argv: [String]?    // command
}

// MARK: - Manifest Loading

enum SecretConfigError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case invalidInject(String)
    case invalidProvider(String)
    case missingProviderField(provider: String, field: String)
    case emptyHosts(secret: String)
    case wildcardHost(secret: String, host: String)
    case providerFailed(secret: String, detail: String)
    case overlappingHost(host: String, existingProject: String, newProject: String)
    case manifestNotFound(String)

    var description: String {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported credentials.toml version: \(v) (expected 1)"
        case .invalidInject(let s):
            return "Invalid inject mode: \(s). Expected \"bearer\", \"basic\", or { type = \"header\", name = \"...\" }"
        case .invalidProvider(let s):
            return "Invalid provider type: \(s). Expected \"env\", \"keychain\", or \"command\""
        case .missingProviderField(let p, let f):
            return "Provider '\(p)' requires field '\(f)'"
        case .emptyHosts(let s):
            return "Secret '\(s)' has empty hosts list"
        case .wildcardHost(let s, let h):
            return "Secret '\(s)': wildcard hosts not supported in v1: \(h)"
        case .providerFailed(let s, let d):
            return "Provider resolution failed for '\(s)': \(d)"
        case .overlappingHost(let h, let existing, let new):
            return "Host '\(h)' declared by project '\(new)' conflicts with project '\(existing)'"
        case .manifestNotFound(let p):
            return "No credentials.toml found at \(p)"
        }
    }
}

extension CredentialManifest {

    /// Parse a `.dvm/credentials.toml` file into a typed manifest.
    static func load(from path: String) throws -> CredentialManifest {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SecretConfigError.manifestNotFound(path)
        }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let raw = try TOMLDecoder().decode(RawManifest.self, from: contents)

        guard raw.version == 1 else {
            throw SecretConfigError.unsupportedVersion(raw.version)
        }

        let rules = try (raw.secrets ?? []).map { try parseSecret($0) }
        return CredentialManifest(version: raw.version, secrets: rules)
    }

    private static func parseSecret(_ raw: RawSecret) throws -> SecretRule {
        guard !raw.hosts.isEmpty else {
            throw SecretConfigError.emptyHosts(secret: raw.name)
        }
        for host in raw.hosts {
            if host.contains("*") {
                throw SecretConfigError.wildcardHost(secret: raw.name, host: host)
            }
        }
        return SecretRule(
            name: raw.name,
            hosts: raw.hosts,
            inject: try parseInject(raw.inject, secret: raw.name),
            provider: try parseProvider(raw.provider, secret: raw.name)
        )
    }

    private static func parseInject(_ raw: RawInject, secret: String) throws -> InjectMode {
        switch raw {
        case .shorthand(let s):
            switch s {
            case "bearer": return .bearer
            case "basic": return .basic
            default: throw SecretConfigError.invalidInject(s)
            }
        case .table(let type, let name):
            guard type == "header" else {
                throw SecretConfigError.invalidInject(type)
            }
            guard let name, !name.isEmpty else {
                throw SecretConfigError.missingProviderField(provider: "header", field: "name")
            }
            return .header(name: name)
        }
    }

    private static func parseProvider(_ raw: RawProvider, secret: String) throws -> SecretProvider {
        switch raw.type {
        case "env":
            guard let name = raw.name, !name.isEmpty else {
                throw SecretConfigError.missingProviderField(provider: "env", field: "name")
            }
            return .env(name: name)
        case "keychain":
            guard let service = raw.service, !service.isEmpty else {
                throw SecretConfigError.missingProviderField(provider: "keychain", field: "service")
            }
            guard let account = raw.account, !account.isEmpty else {
                throw SecretConfigError.missingProviderField(provider: "keychain", field: "account")
            }
            return .keychain(service: service, account: account)
        case "command":
            guard let argv = raw.argv, !argv.isEmpty else {
                throw SecretConfigError.missingProviderField(provider: "command", field: "argv")
            }
            return .command(argv: argv)
        default:
            throw SecretConfigError.invalidProvider(raw.type)
        }
    }
}

// MARK: - Provider Resolution

enum SecretResolver {

    /// Resolve all secrets in a manifest. Validates eagerly — fails on first error.
    static func resolve(_ manifest: CredentialManifest) throws -> [ResolvedSecret] {
        try manifest.secrets.map { rule in
            let value = try resolveProvider(rule.provider, secret: rule.name)
            let placeholder = generatePlaceholder()
            return ResolvedSecret(
                name: rule.name,
                placeholder: placeholder,
                value: value,
                hosts: rule.hosts,
                inject: rule.inject
            )
        }
    }

    private static func resolveProvider(_ provider: SecretProvider, secret: String) throws -> String {
        let raw: String
        switch provider {
        case .env(let name):
            guard let value = ProcessInfo.processInfo.environment[name] else {
                throw SecretConfigError.providerFailed(
                    secret: secret, detail: "environment variable '\(name)' not set")
            }
            raw = value

        case .keychain(let service, let account):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()  // suppress stderr noise
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SecretConfigError.providerFailed(
                    secret: secret,
                    detail: "keychain lookup failed for service='\(service)' account='\(account)' (exit \(process.terminationStatus))")
            }
            raw = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

        case .command(let argv):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SecretConfigError.providerFailed(
                    secret: secret,
                    detail: "command \(argv) failed (exit \(process.terminationStatus))")
            }
            raw = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        }

        // Strip trailing whitespace/newlines, reject empty
        let trimmed = raw.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else {
            throw SecretConfigError.providerFailed(
                secret: secret, detail: "resolved value is empty after trimming")
        }
        return trimmed
    }

    /// Generate a placeholder token: `SANDBOX_SECRET_` + 32 random hex chars.
    static func generatePlaceholder() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "SANDBOX_SECRET_\(hex)"
    }
}

// MARK: - Host Overlap Detection

enum HostOverlapChecker {

    /// Check that no host in `newSecrets` overlaps with any host in `existing`.
    /// `existingProject` / `newProject` are used for error messages.
    static func check(
        existing: [(project: String, secrets: [ResolvedSecret])],
        newProject: String,
        newSecrets: [ResolvedSecret]
    ) throws {
        // Build host -> project index from existing
        var hostIndex: [String: String] = [:]
        for (project, secrets) in existing {
            for secret in secrets {
                for host in secret.hosts {
                    hostIndex[host] = project
                }
            }
        }

        // Check new secrets for overlap
        for secret in newSecrets {
            for host in secret.hosts {
                if let existingProject = hostIndex[host] {
                    throw SecretConfigError.overlappingHost(
                        host: host,
                        existingProject: existingProject,
                        newProject: newProject
                    )
                }
            }
        }
    }
}
