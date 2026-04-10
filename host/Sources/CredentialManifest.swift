import CommonCrypto
import Foundation
import Security
import TOML

// MARK: - Secret Configuration Types

/// How a secret is delivered to the guest.
/// - `proxy`: placeholder injected as env var, real value substituted by MITM proxy on matching hosts.
/// - `passthrough`: real value injected directly as env var, no proxy interception.
enum SecretMode: String, Sendable {
  case proxy
  case passthrough
}

/// A single secret declaration from `.dvm/credentials.toml`.
/// The TOML table determines the mode (`[proxy.*]` or `[passthrough.*]`).
enum SecretSource: Sendable, Equatable {
  case env(name: String)
  case command(argv: [String])
}

struct SecretDecl: Sendable {
  let envVar: String
  let mode: SecretMode
  let source: SecretSource
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
  static func loadOrCreate() throws -> Self {
    try loadOrCreate(at: keyPath)
  }

  /// Load or create at a specific path (used by tests).
  static func loadOrCreate(at path: String) throws -> Self {
    if FileManager.default.fileExists(atPath: path) {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      guard data.count == 32 else {
        throw SecretConfigError.invalidHostKey(path, data.count)
      }
      return Self(bytes: Array(data))
    }

    // Generate new key
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw SecretConfigError.hostKeyGenerationFailed(status)
    }

    // Ensure parent directory exists
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)

    // Write atomically
    let data = Data(bytes)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)

    // Restrict permissions to owner only
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: path)

    return Self(bytes: bytes)
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

// MARK: - TOML Parsing

/// Raw Codable shapes for TOMLDecoder.
/// Format:
/// ```toml
/// version = 0
/// project = "my-project"
///
/// [proxy.ANTHROPIC_API_KEY]
/// hosts = ["api.anthropic.com"]
/// from.command = ["op", "read", "op://Engineering/Anthropic/api key"]
///
/// [passthrough.DB_PASSWORD]
/// from.env = "DATABASE_PASSWORD"
/// ```
private struct RawManifest: Codable {
  let version: Int
  let project: String?
  let proxy: [String: RawProxyEntry]?
  let passthrough: [String: RawPassthroughEntry]?
}

private struct RawProxyEntry: Codable {
  let hosts: [String]
  let from: RawSource?
}

/// Empty struct for passthrough entries (TOML empty tables decode to this).
private struct RawPassthroughEntry: Codable {
  let from: RawSource?
}

private struct RawSource: Codable {
  let env: String?
  let command: [String]?
}

// MARK: - Errors

enum SecretConfigError: Error, CustomStringConvertible {
  case unsupportedVersion(Int)
  case missingProjectName
  case emptyHosts(secret: String)
  case wildcardHost(secret: String, host: String)
  case duplicateSecret(secret: String)
  case envVarNotSet(secret: String, envVar: String)
  case envVarEmpty(secret: String, envVar: String)
  case invalidSource(secret: String)
  case sourceEnvNameEmpty(secret: String)
  case commandEmpty(secret: String)
  case commandFailed(secret: String, command: String, exitCode: Int32, output: String)
  case commandProducedEmptyValue(secret: String, command: String)
  case manifestNotFound(String)
  case manifestUnreadable(String, Error)
  case invalidHostKey(String, Int)
  case hostKeyGenerationFailed(OSStatus)
  case globalPassthroughUnsupported

  var description: String {
    switch self {
    case .unsupportedVersion(let version):
      return "Unsupported credentials.toml version: \(version) (expected 0)"

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

    case let .invalidSource(secret):
      return "Secret '\(secret)': 'from' must specify exactly one of 'env' or 'command'"

    case let .sourceEnvNameEmpty(secret):
      return "Secret '\(secret)': 'from.env' must not be empty"

    case let .commandEmpty(secret):
      return "Secret '\(secret)': 'from.command' must contain at least one argument"

    case let .commandFailed(secret, command, exitCode, output):
      let suffix = output.isEmpty ? "" : " (\(output))"
      return "Secret '\(secret)': command \(command) failed with exit code \(exitCode)\(suffix)"

    case let .commandProducedEmptyValue(secret, command):
      return "Secret '\(secret)': command \(command) produced an empty value"

    case .manifestNotFound(let path):
      return "Credential manifest not found: \(path)"

    case let .manifestUnreadable(path, error):
      return "Failed to read credential manifest at \(path): \(error)"

    case let .invalidHostKey(path, byteCount):
      return "Host key at \(path) has wrong size (\(byteCount) bytes, expected 32)"

    case .hostKeyGenerationFailed(let status):
      return "Failed to generate host key: SecRandomCopyBytes status \(status)"

    case .globalPassthroughUnsupported:
      return
        "Global credential manifests (~/.config/dvm/credentials.toml) only support "
        + "[proxy.*] entries. Global [passthrough.*] secrets are not supported "
        + "for security reasons."
    }
  }
}

// MARK: - Manifest Loading

extension CredentialManifest {
  static func loadLocal(from path: String) throws -> CredentialManifest {
    let raw = try loadRawManifest(from: path)
    guard let project = raw.project else {
      throw SecretConfigError.missingProjectName
    }
    return try buildManifest(raw: raw, projectValue: project, allowPassthrough: true)
  }

  static func loadGlobal(from path: String) throws -> CredentialManifest {
    let raw = try loadRawManifest(from: path)
    return try buildManifest(raw: raw, projectValue: "__global__", allowPassthrough: false)
  }

  private static func loadRawManifest(from path: String) throws -> RawManifest {
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

    guard raw.version == 0 else {
      throw SecretConfigError.unsupportedVersion(raw.version)
    }
    return raw
  }

  private static func buildManifest(
    raw: RawManifest,
    projectValue: String,
    allowPassthrough: Bool
  ) throws -> CredentialManifest {
    let normalizedProject = normalizeProjectName(projectValue)
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

    if !allowPassthrough, !passthroughKeys.isEmpty {
      throw SecretConfigError.globalPassthroughUnsupported
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
        source: try source(for: envVar, rawSource: entry.from),
        hosts: entry.hosts.map { normalizeHost($0) }
      )
    }

    // Parse passthrough entries
    decls += try (raw.passthrough ?? [:]).map { envVar, entry in
      SecretDecl(
        envVar: envVar,
        mode: .passthrough,
        source: try source(for: envVar, rawSource: entry.from),
        hosts: []
      )
    }

    decls.sort { $0.envVar < $1.envVar }  // deterministic order

    return CredentialManifest(
      project: normalizedProject,
      secrets: decls
    )
  }

  private static func source(for secret: String, rawSource: RawSource?) throws -> SecretSource {
    guard let rawSource else {
      return .env(name: secret)
    }

    switch (rawSource.env, rawSource.command) {
    case (nil, nil), (.some, .some):
      throw SecretConfigError.invalidSource(secret: secret)

    case let (.some(envName), nil):
      let trimmed = envName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw SecretConfigError.sourceEnvNameEmpty(secret: secret)
      }
      return .env(name: trimmed)

    case let (nil, .some(argv)):
      return try parseCommandSource(secret: secret, argv: argv)
    }
  }

  private static func parseCommandSource(secret: String, argv: [String]) throws -> SecretSource {
    let trimmedArgv = argv.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let executable = trimmedArgv.first, !executable.isEmpty else {
      throw SecretConfigError.commandEmpty(secret: secret)
    }
    return .command(argv: trimmedArgv)
  }
}

// MARK: - Resolution

extension CredentialManifest {
  /// Resolve secrets from host environment or explicit command sources.
  func resolve(hostKey: HostKey) throws -> [ResolvedSecret] {
    return try resolve(hostKey: hostKey, tolerateMissingHostValues: false).resolved
  }

  func resolve(
    hostKey: HostKey,
    tolerateMissingHostValues: Bool
  ) throws -> (resolved: [ResolvedSecret], warnings: [SecretConfigError]) {
    var resolved: [ResolvedSecret] = []
    var warnings: [SecretConfigError] = []

    for decl in secrets {
      do {
        let trimmed = try resolveValue(for: decl)

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
      } catch let error as SecretConfigError {
        if tolerateMissingHostValues {
          switch error {
          case .envVarNotSet, .envVarEmpty:
            warnings.append(error)
            continue
          default:
            break
          }
        }
        throw error
      }
    }

    return (resolved: resolved, warnings: warnings)
  }

  private func resolveValue(for decl: SecretDecl) throws -> String {
    switch decl.source {
    case .env(let name):
      return try resolveEnvironmentValue(secret: decl.envVar, envVar: name)

    case .command(let argv):
      return try resolveCommandValue(secret: decl.envVar, argv: argv)
    }
  }

  private func resolveEnvironmentValue(secret: String, envVar: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[envVar] else {
      throw SecretConfigError.envVarNotSet(secret: secret, envVar: envVar)
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SecretConfigError.envVarEmpty(secret: secret, envVar: envVar)
    }
    return trimmed
  }

  private func resolveCommandValue(secret: String, argv: [String]) throws -> String {
    let process = makeSourceProcess(argv: argv)
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let commandString = argv.map(shellQuote).joined(separator: " ")
    do {
      try process.run()
    } catch {
      throw SecretConfigError.commandFailed(
        secret: secret,
        command: commandString,
        exitCode: -1,
        output: error.localizedDescription
      )
    }
    process.waitUntilExit()

    let stdoutString =
      String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrString =
      String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
      let output = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
      throw SecretConfigError.commandFailed(
        secret: secret,
        command: commandString,
        exitCode: process.terminationStatus,
        output: output
      )
    }

    let trimmed = stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SecretConfigError.commandProducedEmptyValue(secret: secret, command: commandString)
    }
    return trimmed
  }

  private func makeSourceProcess(argv: [String]) -> Process {
    let process = Process()
    let executable = argv[0]
    if executable.contains("/") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = Array(argv.dropFirst())
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = argv
    }
    process.environment = ProcessInfo.processInfo.environment
    return process
  }
}
