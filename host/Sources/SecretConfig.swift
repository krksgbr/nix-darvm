import CommonCrypto
import Foundation
import Security
import TOML

// MARK: - Secret Configuration Types

/// A single secret declaration from `.dvm/credentials.toml`.
/// The TOML key is the env var name (e.g. `[secrets.ANTHROPIC_API_KEY]`).
struct SecretDecl: Sendable {
    let envVar: String
    let hosts: [String]
}

/// A secret after host-side resolution. The `value` is the real credential —
/// lives in host memory only, never in guest. The `placeholder` is the
/// HMAC-derived token injected into the guest environment.
struct ResolvedSecret: Sendable {
    let name: String
    let placeholder: String
    let value: String
    let hosts: [String]
}

/// Parsed per-project credential manifest (`.dvm/credentials.toml`).
struct CredentialManifest: Sendable {
    let version: Int
    let project: String
    let secrets: [SecretDecl]
}

// MARK: - Host Key

/// 32-byte key for HMAC placeholder derivation. Generated once, stored at
/// `~/.config/dvm/placeholder.key`, never mounted into the guest.
struct HostKey: Sendable {
    let bytes: [UInt8]

    /// Stored under ~/.config/dvm/ (not ~/.local/state/dvm/ which is mounted
    /// into the guest and recreated on every boot).
    static let keyPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/dvm/placeholder.key"
    }()

    /// Load existing key or generate a new one.
    static func loadOrCreate() throws -> HostKey {
        try loadOrCreate(at: keyPath)
    }

    /// Load or create at a specific path (used by tests).
    static func loadOrCreate(at path: String) throws -> HostKey {
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count == 32 else {
                throw SecretConfigError.invalidHostKey(path, data.count)
            }
            return HostKey(bytes: Array(data))
        }

        // Generate new key
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecretConfigError.hostKeyGenerationFailed(status)
        }

        // Ensure parent directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        // Write atomically
        let data = Data(bytes)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        // Restrict permissions to owner only
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)

        return HostKey(bytes: bytes)
    }
}

// MARK: - Placeholder Derivation

/// Derive a deterministic, human-readable placeholder from project + secret + host key.
///
/// Format: `SANDBOX_CRED_{project_slug}_{secret_slug}_{hmac_hex}`
/// - HMAC input: `"{normalized_project}\0{env_var_name}"`
/// - hmac_hex: first 16 hex chars of HMAC-SHA256
///
/// The placeholder is stable (same inputs → same output), traceable (project +
/// secret visible in the string), and not guessable from the guest (HMAC keyed
/// by host-only key).
func derivePlaceholder(project: String, envVar: String, hostKey: HostKey) -> String {
    let normalizedProject = normalizeProjectName(project)
    let projectSlug = slugify(normalizedProject)
    let secretSlug = slugify(envVar)

    // HMAC input: normalized_project + NUL + original env var name
    let input = "\(normalizedProject)\0\(envVar)"
    let inputBytes = Array(input.utf8)

    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
           hostKey.bytes, hostKey.bytes.count,
           inputBytes, inputBytes.count,
           &hmac)

    // First 8 bytes = 16 hex chars
    let suffix = hmac.prefix(8).map { String(format: "%02x", $0) }.joined()

    return "SANDBOX_CRED_\(projectSlug)_\(secretSlug)_\(suffix)"
}

/// Normalize project name for wire protocol and HMAC input.
/// Lowercase, strip leading/trailing whitespace.
func normalizeProjectName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Slugify a string for display in placeholders.
/// Lowercase, non-alphanumeric → hyphen, collapse runs, strip leading/trailing hyphens.
func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var result = ""
    var lastWasHyphen = false
    for c in lowered {
        if c.isLetter || c.isNumber {
            result.append(c)
            lastWasHyphen = false
        } else if !lastWasHyphen {
            result.append("-")
            lastWasHyphen = true
        }
    }
    // Strip leading/trailing hyphens
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// Normalize a hostname for matching: lowercase, strip trailing dots.
/// Matches the Go sidecar's `normalizeHost()`.
func normalizeHost(_ host: String) -> String {
    var h = host.lowercased()
    while h.hasSuffix(".") {
        h.removeLast()
    }
    return h
}

// MARK: - TOML Parsing (v2 format)

/// Raw Codable shapes for TOMLDecoder.
/// Format:
/// ```toml
/// version = 1
/// project = "my-project"
///
/// [secrets.ANTHROPIC_API_KEY]
/// hosts = ["api.anthropic.com"]
/// ```
private struct RawManifest: Codable {
    let version: Int
    let project: String
    let secrets: [String: RawSecretEntry]?
}

private struct RawSecretEntry: Codable {
    let hosts: [String]
}

// MARK: - Errors

enum SecretConfigError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case missingProjectName
    case emptyHosts(secret: String)
    case wildcardHost(secret: String, host: String)
    case envVarNotSet(secret: String, envVar: String)
    case envVarEmpty(secret: String, envVar: String)
    case manifestNotFound(String)
    case manifestUnreadable(String, Error)
    case invalidHostKey(String, Int)
    case hostKeyGenerationFailed(OSStatus)

    var description: String {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported credentials.toml version: \(v) (expected 1)"
        case .missingProjectName:
            return "credentials.toml missing required 'project' field"
        case .emptyHosts(let s):
            return "Secret '\(s)' has empty hosts list"
        case .wildcardHost(let s, let h):
            return "Secret '\(s)': wildcard hosts not supported: \(h)"
        case .envVarNotSet(let s, let v):
            return "Secret '\(s)': environment variable '\(v)' is not set"
        case .envVarEmpty(let s, let v):
            return "Secret '\(s)': environment variable '\(v)' is set but empty"
        case .manifestNotFound(let p):
            return "Credential manifest not found: \(p)"
        case .manifestUnreadable(let p, let e):
            return "Failed to read credential manifest at \(p): \(e)"
        case .invalidHostKey(let p, let n):
            return "Host key at \(p) has wrong size (\(n) bytes, expected 32)"
        case .hostKeyGenerationFailed(let s):
            return "Failed to generate host key: SecRandomCopyBytes status \(s)"
        }
    }
}

// MARK: - Manifest Loading

extension CredentialManifest {

    /// Parse a `.dvm/credentials.toml` file into a typed manifest.
    static func load(from path: String) throws -> CredentialManifest {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SecretConfigError.manifestNotFound(path)
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SecretConfigError.manifestUnreadable(path, error)
        }
        let raw = try TOMLDecoder().decode(RawManifest.self, from: contents)

        guard raw.version == 1 else {
            throw SecretConfigError.unsupportedVersion(raw.version)
        }

        let normalizedProject = normalizeProjectName(raw.project)
        guard !normalizedProject.isEmpty else {
            throw SecretConfigError.missingProjectName
        }

        let decls: [SecretDecl] = try (raw.secrets ?? [:]).map { envVar, entry in
            guard !entry.hosts.isEmpty else {
                throw SecretConfigError.emptyHosts(secret: envVar)
            }
            for host in entry.hosts {
                if host.contains("*") {
                    throw SecretConfigError.wildcardHost(secret: envVar, host: host)
                }
            }
            return SecretDecl(
                envVar: envVar,
                hosts: entry.hosts.map { normalizeHost($0) }
            )
        }.sorted(by: { $0.envVar < $1.envVar })  // deterministic order

        return CredentialManifest(
            version: raw.version,
            project: normalizedProject,
            secrets: decls
        )
    }
}

// MARK: - Resolution

extension CredentialManifest {

    /// Resolve all secrets from host environment. Fails loudly on first missing var.
    func resolve(hostKey: HostKey) throws -> [ResolvedSecret] {
        try secrets.map { decl in
            guard let value = ProcessInfo.processInfo.environment[decl.envVar] else {
                throw SecretConfigError.envVarNotSet(
                    secret: decl.envVar, envVar: decl.envVar)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SecretConfigError.envVarEmpty(
                    secret: decl.envVar, envVar: decl.envVar)
            }
            let placeholder = derivePlaceholder(
                project: project, envVar: decl.envVar, hostKey: hostKey)
            return ResolvedSecret(
                name: decl.envVar,
                placeholder: placeholder,
                value: trimmed,
                hosts: decl.hosts
            )
        }
    }
}
