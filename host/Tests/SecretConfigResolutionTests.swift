import Foundation
import Security
import XCTest

// MARK: - Manifest Resolution

final class ManifestResolveTests: XCTestCase {

  let testKey = HostKey(bytes: Array(repeating: 0x42, count: 32))

  func testResolveProxySuccess() throws {
    let envVar = "DVM_TEST_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "secret-value", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .proxy, hosts: ["example.com"])]
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
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .passthrough, hosts: [])]
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
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .proxy, hosts: ["example.com"])]
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
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .passthrough, hosts: [])]
    )

    XCTAssertThrowsError(try manifest.resolve(hostKey: testKey)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains(envVar), "Error should name the variable: \(desc)")
      XCTAssertTrue(desc.contains("not set"), "Error should say 'not set': \(desc)")
    }
  }

  func testResolveEmptyEnvVar() {
    let envVar = "DVM_TEST_EMPTY_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "  \n  ", 1)  // whitespace-only
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .proxy, hosts: ["example.com"])]
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
      version: 1,
      project: "test",
      secrets: [SecretDecl(envVar: envVar, mode: .proxy, hosts: ["example.com"])]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved[0].value, "secret-with-whitespace")
  }

  func testResolvePlaceholderMatchesDerivation() throws {
    let envVar = "DVM_TEST_DERIVE_\(UUID().uuidString.prefix(8).uppercased())"
    setenv(envVar, "value", 1)
    defer { unsetenv(envVar) }

    let manifest = CredentialManifest(
      version: 1,
      project: "my-project",
      secrets: [SecretDecl(envVar: envVar, mode: .proxy, hosts: ["example.com"])]
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
      version: 1,
      project: "test",
      secrets: [
        SecretDecl(envVar: var1, mode: .proxy, hosts: ["a.com"]),
        SecretDecl(envVar: var2, mode: .proxy, hosts: ["b.com"])
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
      version: 1,
      project: "test",
      secrets: [
        SecretDecl(envVar: proxyVar, mode: .proxy, hosts: ["a.com"]),
        SecretDecl(envVar: ptVar, mode: .passthrough, hosts: [])
      ]
    )

    let resolved = try manifest.resolve(hostKey: testKey)
    XCTAssertEqual(resolved.count, 2)

    let proxy = resolved.first { $0.mode == .proxy }!
    let passthrough = resolved.first { $0.mode == .passthrough }!

    XCTAssertTrue(proxy.placeholder.hasPrefix("SANDBOX_CRED_"))
    XCTAssertNotEqual(proxy.placeholder, proxy.value)

    XCTAssertEqual(passthrough.placeholder, "passthrough-val")
    XCTAssertEqual(passthrough.value, "passthrough-val")
  }
}

// MARK: - HostKey Filesystem

final class HostKeyTests: XCTestCase {

  func testLoadOrCreate_generatesNewKey() throws {
    let dir = NSTemporaryDirectory() + "dvm-hostkey-test-\(UUID().uuidString)"
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

  func testLoadOrCreate_rejectsWrongSize() {
    let dir = NSTemporaryDirectory() + "dvm-hostkey-test-\(UUID().uuidString)"
    let path = dir + "/placeholder.key"
    try! FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    // Write a 16-byte key (wrong size)
    try! Data(repeating: 0x00, count: 16).write(to: URL(fileURLWithPath: path))

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
    let perms = (attrs[.posixPermissions] as! NSNumber).intValue
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
