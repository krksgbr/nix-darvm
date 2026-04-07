import Foundation

/// Discover the credential manifest path based on the priority chain:
/// `--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd.
/// Returns nil if no manifest is found (CWD fallback only).
/// Explicit sources (flag, env var) that point to missing files throw.
func discoverManifestPath(
  credentialsFlag: String?,
  cwd: String
) throws -> String? {
  if let flag = credentialsFlag {
    let resolved = URL(fileURLWithPath: flag, relativeTo: URL(fileURLWithPath: cwd))
      .standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: resolved) else {
      throw SecretConfigError.manifestNotFound(resolved)
    }
    return resolved
  }
  if let envPath = ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] {
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
  let cwdManifest = URL(fileURLWithPath: cwd).appendingPathComponent(".dvm/credentials.toml").path
  return FileManager.default.fileExists(atPath: cwdManifest) ? cwdManifest : nil
}

func resolveAndPushCredentials(
  credentialsFlag: String?,
  cwd: String
) throws -> [String: String] {
  let explicit =
    credentialsFlag != nil
    || ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] != nil

  guard
    let path = try discoverManifestPath(
      credentialsFlag: credentialsFlag, cwd: cwd)
  else {
    return [:]
  }

  do {
    let manifest = try CredentialManifest.load(from: path)
    let hostKey = try HostKey.loadOrCreate()
    let secrets = try manifest.resolve(hostKey: hostKey)
    let proxySecrets = secrets.filter { $0.mode == .proxy }

    if let error = ControlSocket.sendLoadCredentials(
      projectName: manifest.project, secrets: proxySecrets)
    {
      throw CredentialPushError(detail: error)
    }

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

struct CredentialPushError: Error, CustomStringConvertible {
  let detail: String
  var description: String { "Failed to push credentials to proxy: \(detail)" }
}
