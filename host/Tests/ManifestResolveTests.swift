import Foundation
import Security
import XCTest

@testable import dvm_core

// MARK: - Manifest Resolution

final class ManifestResolveTests: XCTestCase {
  private let testKey = HostKey(bytes: Array(repeating: 0x42, count: 32))

  func testResolveProxySuccess() throws {
    let envVar = "DVM_TEST_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "secret-value", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .env(name: envVar),
          hosts: ["example.com"]
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved[0].name, envVar)
    XCTAssertEqual(resolved[0].mode, .proxy)
    XCTAssertEqual(resolved[0].value, "secret-value")
    XCTAssertTrue(resolved[0].placeholder.hasPrefix("SANDBOX_CRED_"))
    XCTAssertNotEqual(resolved[0].placeholder, resolved[0].value)
    XCTAssertEqual(resolved[0].hosts, ["example.com"])
  }

  func testResolvePassthroughSuccess() throws {
    let envVar = "DVM_TEST_PT_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "db-password-value", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .passthrough,
          source: .env(name: envVar),
          hosts: []
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved[0].name, envVar)
    XCTAssertEqual(resolved[0].mode, .passthrough)
    XCTAssertEqual(resolved[0].value, "db-password-value")
    // Passthrough: placeholder IS the real value
    XCTAssertEqual(resolved[0].placeholder, "db-password-value")
    XCTAssertEqual(resolved[0].hosts, [])
  }

  func testResolveMissingEnvVar() {
    let envVar = "DVM_TEST_MISSING_\(UUID().uuidString.prefix(8).uppercased())"
    unsetenv(envVar)

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .env(name: envVar),
          hosts: ["example.com"]
        )
      ]
    )

    XCTAssertThrowsError(try manifest.resolve(hostKey: testKey)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains(envVar), "Error should name the variable: \(desc)")
      XCTAssertTrue(desc.contains("not set"), "Error should say 'not set': \(desc)")
    }
  }

  func testResolveMissingEnvVarPassthrough() {
    let envVar = "DVM_TEST_MISSING_PT_\(UUID().uuidString.prefix(8).uppercased())"
    unsetenv(envVar)

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .passthrough,
          source: .env(name: envVar),
          hosts: []
        )
      ]
    )

    XCTAssertThrowsError(try manifest.resolve(hostKey: testKey)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains(envVar), "Error should name the variable: \(desc)")
      XCTAssertTrue(desc.contains("not set"), "Error should say 'not set': \(desc)")
    }
  }

  func testResolveTolerantModeSkipsMissingEnvSecrets() throws {
    let proxyVar = "DVM_TEST_PROXY_\(UUID().uuidString.prefix(8).uppercased())"
    let passthroughVar = "DVM_TEST_PT_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(proxyVar, "proxy-value", 1)
    unsetenv(passthroughVar)

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: proxyVar,
          mode: .proxy,
          source: .env(name: proxyVar),
          hosts: ["example.com"]
        ),
        SecretDecl(
          envVar: passthroughVar,
          mode: .passthrough,
          source: .env(name: passthroughVar),
          hosts: []
        ),
      ]
    )
    defer {
      unsetenv(proxyVar)
    }

    let result = try manifest.resolve(
      hostKey: testKey,
      tolerateMissingHostValues: true
    )

    XCTAssertEqual(result.resolved.count, 1)
    XCTAssertEqual(result.resolved[0].name, proxyVar)
    XCTAssertEqual(result.warnings.count, 1)
    if case let .envVarNotSet(secret: secret, envVar: envVar) = result.warnings[0] {
      XCTAssertEqual(secret, passthroughVar)
      XCTAssertEqual(envVar, passthroughVar)
    } else {
      XCTFail("Expected missing host env warning: \(result.warnings[0])")
    }
  }

  func testResolveTolerantModeDoesNotSuppressCommandErrors() {
    let envVar = "DVM_TEST_MISSING_CMD_\(UUID().uuidString.prefix(8).uppercased())"
    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .command(argv: ["/bin/sh", "-c", "exit 42"]),
          hosts: ["example.com"]
        ),
      ]
    )

    XCTAssertThrowsError(
      try manifest.resolve(hostKey: testKey, tolerateMissingHostValues: true)
    ) { error in
      let description = String(describing: error)
      XCTAssertTrue(description.contains("exit 42"))
    }
  }

  func testResolveEmptyEnvVar() {
    let envVar = "DVM_TEST_EMPTY_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "  \n  ", 1)  // whitespace-only
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .env(name: envVar),
          hosts: ["example.com"]
        )
      ]
    )

    XCTAssertThrowsError(try manifest.resolve(hostKey: testKey)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains(envVar), "Error should name the variable: \(desc)")
      XCTAssertTrue(desc.contains("empty"), "Error should say 'empty': \(desc)")
    }
  }

  func testResolveTrimsWhitespace() throws {
    let envVar = "DVM_TEST_TRIM_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "  secret-with-whitespace  \n", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .env(name: envVar),
          hosts: ["example.com"]
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved[0].value, "secret-with-whitespace")
  }

  func testResolvePlaceholderMatchesDerivation() throws {
    let envVar = "DVM_TEST_DERIVE_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "value", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      project: "my-project",
      secrets: [
        SecretDecl(
          envVar: envVar,
          mode: .proxy,
          source: .env(name: envVar),
          hosts: ["example.com"]
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    let expected = derivePlaceholder(project: "my-project", envVar: envVar, hostKey: testKey)
    XCTAssertEqual(resolved[0].placeholder, expected)
  }

  func testResolveMultipleSecrets() throws {
    let var1 = "DVM_TEST_MULTI1_\(UUID().uuidString.prefix(8).uppercased())"
    let var2 = "DVM_TEST_MULTI2_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(var1, "val1", 1)
    setenv(var2, "val2", 1)
    defer {
      unsetenv(var1)
      unsetenv(var2)
    }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(envVar: var1, mode: .proxy, source: .env(name: var1), hosts: ["a.com"]),
        SecretDecl(envVar: var2, mode: .proxy, source: .env(name: var2), hosts: ["b.com"])
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved.count, 2)
    XCTAssertNotEqual(resolved[0].placeholder, resolved[1].placeholder)
  }

  func testResolveMixedModes() throws {
    let proxyVar = "DVM_TEST_PROXY_\(UUID().uuidString.prefix(8).uppercased())"
    let ptVar = "DVM_TEST_PT_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(proxyVar, "proxy-val", 1)
    setenv(ptVar, "passthrough-val", 1)
    defer {
      unsetenv(proxyVar)
      unsetenv(ptVar)
    }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(envVar: proxyVar, mode: .proxy, source: .env(name: proxyVar), hosts: ["a.com"]),
        SecretDecl(envVar: ptVar, mode: .passthrough, source: .env(name: ptVar), hosts: [])
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved.count, 2)

    let proxy = try XCTUnwrap(resolved.first { $0.mode == .proxy })
    let passthrough = try XCTUnwrap(resolved.first { $0.mode == .passthrough })

    XCTAssertTrue(proxy.placeholder.hasPrefix("SANDBOX_CRED_"))
    XCTAssertNotEqual(proxy.placeholder, proxy.value)

    XCTAssertEqual(passthrough.placeholder, "passthrough-val")
    XCTAssertEqual(passthrough.value, "passthrough-val")
  }

  func testResolveExplicitEnvSource() throws {
    let secretName = "OPENAI_API_KEY"
    let hostEnv = "HOST_OPENAI_TOKEN_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(hostEnv, "mapped-secret", 1)
    defer { unsetenv(hostEnv) }

    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: secretName,
          mode: .proxy,
          source: .env(name: hostEnv),
          hosts: ["api.openai.com"]
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved[0].name, secretName)
    XCTAssertEqual(resolved[0].value, "mapped-secret")
  }

  func testResolveCommandSource() throws {
    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: "OPENAI_API_KEY",
          mode: .proxy,
          source: .command(argv: ["/bin/sh", "-c", "printf 'command-secret\\n'"]),
          hosts: ["api.openai.com"]
        )
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved[0].value, "command-secret")
  }

  func testResolveCommandFailure() {
    let manifest = CredentialManifest(
      project: "test",
      secrets: [
        SecretDecl(
          envVar: "OPENAI_API_KEY",
          mode: .proxy,
          source: .command(argv: ["/bin/sh", "-c", "echo 'boom' >&2; exit 7"]),
          hosts: ["api.openai.com"]
        )
      ]
    )

    XCTAssertThrowsError(try manifest.resolve(hostKey: testKey)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains("exit code 7"), "Error should preserve exit code: \(desc)")
      XCTAssertTrue(desc.contains("boom"), "Error should preserve stderr: \(desc)")
    }
  }
}

// MARK: - HostKey Filesystem

final class HostKeyTests: XCTestCase {
  func testLoadOrCreate_generatesNewKey() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dvm-hostkey-test-\(UUID().uuidString)")
      .path
    let path = dir + "/placeholder.key"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let key = try HostKey.loadOrCreate(at: path)
    XCTAssertEqual(key.bytes.count, 32)

    // File should exist with correct size
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(data.count, 32)
    XCTAssertEqual(Array(data), key.bytes)
  }

  func testLoadOrCreate_persistsAcrossCalls() throws {
    let dir = NSTemporaryDirectory() + "dvm-hostkey-test-\(UUID().uuidString)"
    let path = dir + "/placeholder.key"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let key1 = try HostKey.loadOrCreate(at: path)
    let key2 = try HostKey.loadOrCreate(at: path)
    XCTAssertEqual(key1.bytes, key2.bytes, "Same key should be loaded from disk")
  }

  func testLoadOrCreate_rejectsWrongSize() throws {
    let dir = NSTemporaryDirectory() + "dvm-hostkey-test-\(UUID().uuidString)"
    let path = dir + "/placeholder.key"
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    // Write a 16-byte key (wrong size)
    try Data(repeating: 0x00, count: 16).write(to: URL(fileURLWithPath: path))

    XCTAssertThrowsError(try HostKey.loadOrCreate(at: path)) { error in
      let description = String(describing: error)
      XCTAssertTrue(
        description.contains("wrong size") || description.contains("32"),
        "Error should mention expected size: \(description)")
    }
  }

  func testLoadOrCreate_setsRestrictedPermissions() throws {
    let dir = NSTemporaryDirectory() + "dvm-hostkey-test-\(UUID().uuidString)"
    let path = dir + "/placeholder.key"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try HostKey.loadOrCreate(at: path)

    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let perms = try XCTUnwrap(attrs[.posixPermissions] as? Int)
    XCTAssertEqual(perms, 0o600, "Key file should be owner-only (0600)")
  }

  func testDefaultKeyPath_isUnderConfig() {
    // Regression: key must NOT be under ~/.local/state/dvm/ (mounted into guest)
    XCTAssertTrue(
      HostKey.keyPath.contains("/.config/dvm/"),
      "Key path should be under ~/.config/dvm/, got: \(HostKey.keyPath)")
    XCTAssertFalse(
      HostKey.keyPath.contains("/.local/state/"),
      "Key path must NOT be under ~/.local/state/: \(HostKey.keyPath)")
  }
}
