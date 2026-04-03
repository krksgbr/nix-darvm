import CommonCrypto
import Foundation
import Security
import TOML

// MARK: - Secret Configuration Types

/// How a secret is delivered to the guest.
/// - `proxy`: placeholder injected as env var, real value substituted by MITM proxy on matching hosts.
/// - `passthrough`: real value injected directly as env var, no proxy interception.
enum SecretMode: String, Sendable {
  case proxy = "proxy"
  case passthrough = "passthrough"
}

/// A single secret declaration from `.dvm/credentials.toml`.
/// The TOML table determines the mode (`[proxy.*]` or `[passthrough.*]`).
struct SecretDecl: Sendable {
  let envVar: String
  let mode: SecretMode
  let hosts: [String]  // non-empty for proxy, empty for passthrough
}

/// A secret after host-side resolution. The `value` is the real credential —
/// lives in host memory only, never in guest (for proxy mode). For passthrough
/// mode the real value is injected directly into the guest environment.
/// The `placeholder` is the HMAC-derived token (proxy) or the real value (passthrough).
struct ResolvedSecret: Sendable {
  let name: String
  let mode: SecretMode
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
  CCHmac(
    CCHmacAlgorithm(kCCHmacAlgSHA256),
    hostKey.bytes,
    hostKey.bytes.count,
    inputBytes,
    inputBytes.count,
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
func slugify(_ string: String) -> String {
  let lowered = string.lowercased()
  var result = ""
  var lastWasHyphen = false
  for character in lowered {
    if character.isLetter || character.isNumber {
      result.append(character)
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
  var normalizedHost = host.lowercased()
  while normalizedHost.hasSuffix(".") {
    normalizedHost.removeLast()
  }
  return normalizedHost
}

// MARK: - TOML Parsing (v2 format)

/// Raw Codable shapes for TOMLDecoder.
/// Format:
/// ```toml
/// version = 1
/// project = "my-project"
///
/// [proxy.ANTHROPIC_API_KEY]
/// hosts = ["api.anthropic.com"]
///
/// [passthrough.DB_PASSWORD]
/// ```
private struct RawManifest: Codable {
  let version: Int
  let project: String
  let proxy: [String: RawProxyEntry]?
  let passthrough: [String: RawPassthroughEntry]?
}

private struct RawProxyEntry: Codable {
  let hosts: [String]
}

/// Empty struct for passthrough entries (TOML empty tables decode to this).
private struct RawPassthroughEntry: Codable {}

// MARK: - Errors

enum SecretConfigError: Error, CustomStringConvertible {
  case unsupportedVersion(Int)
  case missingProjectName
  case emptyHosts(secret: String)
  case wildcardHost(secret: String, host: String)
  case duplicateSecret(secret: String)
  case envVarNotSet(secret: String, envVar: String)
  case envVarEmpty(secret: String, envVar: String)
  case manifestNotFound(String)
  case manifestUnreadable(String, Error)
  case invalidHostKey(String, Int)
  case hostKeyGenerationFailed(OSStatus)

  var description: String {
    switch self {
    case .unsupportedVersion(let version):
      return "Unsupported credentials.toml version: \(version) (expected 1)"

    case .missingProjectName:
      return "credentials.toml missing required 'project' field"

    case .duplicateSecret(let secret):
      return "Secret '\(secret)' appears in both [proxy] and [passthrough] tables"

    case .emptyHosts(let secret):
      return "Secret '\(secret)' has empty hosts list"

    case let .wildcardHost(secret, host):
      return "Secret '\(secret)': wildcard hosts not supported: \(host)"

    case let .envVarNotSet(secret, envVar):
      return "Secret '\(secret)': environment variable '\(envVar)' is not set"

    case let .envVarEmpty(secret, envVar):
      return "Secret '\(secret)': environment variable '\(envVar)' is set but empty"

    case .manifestNotFound(let path):
      return "Credential manifest not found: \(path)"

    case let .manifestUnreadable(path, error):
      return "Failed to read credential manifest at \(path): \(error)"

    case let .invalidHostKey(path, byteCount):
      return "Host key at \(path) has wrong size (\(byteCount) bytes, expected 32)"

    case .hostKeyGenerationFailed(let status):
      return "Failed to generate host key: SecRandomCopyBytes status \(status)"
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

    // Check for duplicate secret names across both tables
    let proxyKeys = Set((raw.proxy ?? [:]).keys)
    let passthroughKeys = Set((raw.passthrough ?? [:]).keys)
    let duplicates = proxyKeys.intersection(passthroughKeys)
    if let first = duplicates.min() {
      throw SecretConfigError.duplicateSecret(secret: first)
    }

    // Parse proxy entries
    var decls: [SecretDecl] = try (raw.proxy ?? [:]).map { envVar, entry in
      guard !entry.hosts.isEmpty else {
        throw SecretConfigError.emptyHosts(secret: envVar)
      }
      for host in entry.hosts where host.contains("*") {
        throw SecretConfigError.wildcardHost(secret: envVar, host: host)
      }
      return SecretDecl(
        envVar: envVar,
        mode: .proxy,
        hosts: entry.hosts.map { normalizeHost($0) }
      )
    }

    // Parse passthrough entries
    decls += (raw.passthrough ?? [:]).map { envVar, _ in
      SecretDecl(envVar: envVar, mode: .passthrough, hosts: [])
    }

    decls.sort { $0.envVar < $1.envVar }  // deterministic order

    return CredentialManifest(
      version: raw.version,
      project: normalizedProject,
      secrets: decls
    )
  }
}

// MARK: - Resolution

extension CredentialManifest {
  /// Resolve secrets from host environment.
  /// Missing or empty env vars are skipped with a per-secret warning.
  /// Structural errors (bad format, duplicate secrets) still throw.
  func resolve(hostKey: HostKey) throws -> [ResolvedSecret] {
    var resolved: [ResolvedSecret] = []
    for decl in secrets {
      guard let value = ProcessInfo.processInfo.environment[decl.envVar] else {
        fputs(
          "Warning: skipping credential '\(decl.envVar)': environment variable '\(decl.envVar)' is not set\n",
          stderr)
        continue
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        fputs(
          "Warning: skipping credential '\(decl.envVar)': environment variable '\(decl.envVar)' is set but empty\n",
          stderr)
        continue
      }

      switch decl.mode {
      case .proxy:
        let placeholder = derivePlaceholder(
          project: project, envVar: decl.envVar, hostKey: hostKey)
        resolved.append(
          ResolvedSecret(
            name: decl.envVar,
            mode: .proxy,
            placeholder: placeholder,
            value: trimmed,
            hosts: decl.hosts
          ))

      case .passthrough:
        // Passthrough: real value injected directly, no proxy interception
        resolved.append(
          ResolvedSecret(
            name: decl.envVar,
            mode: .passthrough,
            placeholder: trimmed,
            value: trimmed,
            hosts: []
          ))
      }
    }
    return resolved
  }
}
