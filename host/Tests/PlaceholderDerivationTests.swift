import Foundation
import Security
import XCTest

@testable import dvm_core

// MARK: - Placeholder Derivation

final class PlaceholderDerivationTests: XCTestCase {
  private let testKey = HostKey(bytes: Array(repeating: 0x42, count: 32))

  func testFormat() throws {
    let placeholder = derivePlaceholder(project: "My Project", envVar: "API_KEY", hostKey: testKey)
    XCTAssertTrue(placeholder.hasPrefix("SANDBOX_CRED_"))
    // Should contain slugified project and secret
    XCTAssertTrue(placeholder.contains("my-project"), "Expected slugified project in: \(placeholder)")
    XCTAssertTrue(placeholder.contains("api-key"), "Expected slugified secret in: \(placeholder)")
    // HMAC suffix: 16 hex chars
    let parts = placeholder.split(separator: "_")
    let hmacSuffix = try XCTUnwrap(parts.last).description
    XCTAssertEqual(hmacSuffix.count, 16)
    XCTAssertTrue(hmacSuffix.allSatisfy(\.isHexDigit))
  }

  func testDeterministic() {
    let firstPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
    let secondPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
    XCTAssertEqual(firstPlaceholder, secondPlaceholder)
  }

  func testDifferentProjectsDifferentPlaceholders() {
    let firstPlaceholder = derivePlaceholder(project: "proj-a", envVar: "KEY", hostKey: testKey)
    let secondPlaceholder = derivePlaceholder(project: "proj-b", envVar: "KEY", hostKey: testKey)
    XCTAssertNotEqual(firstPlaceholder, secondPlaceholder)
  }

  func testDifferentSecretsDifferentPlaceholders() {
    let firstPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY_A", hostKey: testKey)
    let secondPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY_B", hostKey: testKey)
    XCTAssertNotEqual(firstPlaceholder, secondPlaceholder)
  }

  func testDifferentKeysDifferentPlaceholders() {
    let key2 = HostKey(bytes: Array(repeating: 0x43, count: 32))
    let firstPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
    let secondPlaceholder = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: key2)
    XCTAssertNotEqual(firstPlaceholder, secondPlaceholder)
  }

  func testProjectNormalization() {
    // "My Project" and "  my project  " should produce the same placeholder
    let firstPlaceholder = derivePlaceholder(project: "My Project", envVar: "KEY", hostKey: testKey)
    let secondPlaceholder = derivePlaceholder(
      project: "  my project  ",
      envVar: "KEY",
      hostKey: testKey
    )
    XCTAssertEqual(firstPlaceholder, secondPlaceholder)
  }
}

// MARK: - Slugify

final class SlugifyTests: XCTestCase {
  func testBasic() {
    XCTAssertEqual(slugify("HELLO_WORLD"), "hello-world")
  }

  func testSpecialChars() {
    XCTAssertEqual(slugify("foo.bar@baz"), "foo-bar-baz")
  }

  func testCollapseHyphens() {
    XCTAssertEqual(slugify("foo---bar"), "foo-bar")
  }

  func testStripEdgeHyphens() {
    XCTAssertEqual(slugify("--hello--"), "hello")
  }

  func testPreserveNumbers() {
    XCTAssertEqual(slugify("key123"), "key123")
  }

  func testAlreadySlug() {
    XCTAssertEqual(slugify("already-a-slug"), "already-a-slug")
  }

  func testEmpty() {
    XCTAssertEqual(slugify(""), "")
  }

  func testOnlySpecialChars() {
    XCTAssertEqual(slugify("@#$%"), "")
  }
}

// MARK: - Normalize

final class NormalizeTests: XCTestCase {
  func testNormalizeProjectName_lowercaseAndTrim() {
    XCTAssertEqual(normalizeProjectName("  My Project  "), "my project")
  }

  func testNormalizeProjectName_alreadyNormalized() {
    XCTAssertEqual(normalizeProjectName("my-project"), "my-project")
  }

  func testNormalizeProjectName_tabsAndNewlines() {
    XCTAssertEqual(normalizeProjectName("\t My Project \n"), "my project")
  }

  func testNormalizeHost_lowercaseAndStripDots() {
    XCTAssertEqual(normalizeHost("API.Example.COM."), "api.example.com")
  }

  func testNormalizeHost_multipleTrailingDots() {
    XCTAssertEqual(normalizeHost("host..."), "host")
  }

  func testNormalizeHost_noDots() {
    XCTAssertEqual(normalizeHost("localhost"), "localhost")
  }

  func testNormalizeHost_preservesInternalDots() {
    XCTAssertEqual(normalizeHost("a.b.c.d"), "a.b.c.d")
  }
}

// MARK: - Manifest Loading

final class ManifestLoadCoreTests: XCTestCase {
  func testValidManifest() throws {
    let toml = """
      version = 0
      project = "test-project"

      [proxy.API_KEY]
      hosts = ["api.example.com"]

      [proxy.OTHER_KEY]
      hosts = ["other.example.com", "api.example.com"]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.project, "test-project")
    XCTAssertEqual(manifest.secrets.count, 2)
    // Sorted by envVar
    XCTAssertEqual(manifest.secrets[0].envVar, "API_KEY")
    XCTAssertEqual(manifest.secrets[0].mode, .proxy)
    XCTAssertEqual(manifest.secrets[0].source, .env(name: "API_KEY"))
    XCTAssertEqual(manifest.secrets[1].envVar, "OTHER_KEY")
    XCTAssertEqual(manifest.secrets[1].mode, .proxy)
    XCTAssertEqual(manifest.secrets[1].source, .env(name: "OTHER_KEY"))
  }

  func testMissingFile() {
    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: "/nonexistent/path.toml")) { error in
      guard let secretConfigError = error as? SecretConfigError else {
        return XCTFail("Expected SecretConfigError, got \(error)")
      }
      XCTAssertTrue(String(describing: secretConfigError).contains("not found"))
    }
  }

  func testMalformedToml() throws {
    let path = try writeTempTOML("this is not valid toml {{{")
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path))
  }

  func testWrongVersion() throws {
    let toml = """
      version = 99
      project = "test"
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("version"))
    }
  }

  func testMissingProject() throws {
    let toml = """
      version = 0
      project = ""
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("project"))
    }
  }

  func testMissingProjectField() throws {
    // project field absent entirely (not just empty)
    let toml = """
      version = 0
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path))
  }

  func testWhitespaceOnlyProject() throws {
    let toml = """
      version = 0
      project = "   "
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("project"))
    }
  }

  func testEmptyHosts() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.KEY]
      hosts = []
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("empty"))
    }
  }

  func testWildcardHost() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.KEY]
      hosts = ["*.example.com"]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("wildcard"))
    }
  }

  func testHostsNormalized() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.KEY]
      hosts = ["API.Example.COM."]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets[0].hosts, ["api.example.com"])
  }

  func testNoSecrets() throws {
    let toml = """
      version = 0
      project = "test"
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertTrue(manifest.secrets.isEmpty)
  }
}

final class ManifestLoadSourceTests: XCTestCase {
  func testProjectNormalized() throws {
    let toml = """
      version = 0
      project = "  MY PROJECT  "
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.project, "my project")
  }

  func testSecretsSortedByEnvVar() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.ZEBRA]
      hosts = ["z.com"]

      [proxy.ALPHA]
      hosts = ["a.com"]

      [passthrough.MIDDLE]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets.map(\.envVar), ["ALPHA", "MIDDLE", "ZEBRA"])
    XCTAssertEqual(manifest.secrets[0].mode, .proxy)
    XCTAssertEqual(manifest.secrets[1].mode, .passthrough)
    XCTAssertEqual(manifest.secrets[2].mode, .proxy)
  }

  func testPassthroughEntries() throws {
    let toml = """
      version = 0
      project = "test"

      [passthrough.DB_PASSWORD]
      [passthrough.AUTH_SECRET]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets.count, 2)
    XCTAssertEqual(manifest.secrets[0].mode, .passthrough)
    XCTAssertEqual(manifest.secrets[0].hosts, [])
    XCTAssertEqual(manifest.secrets[1].mode, .passthrough)
    XCTAssertEqual(manifest.secrets[1].hosts, [])
  }

  func testDuplicateSecretAcrossTables() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.MY_KEY]
      hosts = ["example.com"]

      [passthrough.MY_KEY]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      let desc = String(describing: error)
      XCTAssertTrue(desc.contains("MY_KEY"), "Error should name the duplicate: \(desc)")
      XCTAssertTrue(desc.contains("both"), "Error should mention both tables: \(desc)")
    }
  }

  func testMixedProxyAndPassthrough() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.API_KEY]
      hosts = ["api.example.com"]

      [passthrough.DB_PASSWORD]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets.count, 2)
    let proxySecret = try XCTUnwrap(manifest.secrets.first { $0.envVar == "API_KEY" })
    let passthroughSecret = try XCTUnwrap(manifest.secrets.first { $0.envVar == "DB_PASSWORD" })
    XCTAssertEqual(proxySecret.mode, .proxy)
    XCTAssertEqual(proxySecret.hosts, ["api.example.com"])
    XCTAssertEqual(passthroughSecret.mode, .passthrough)
    XCTAssertEqual(passthroughSecret.hosts, [])
  }

  func testExplicitEnvSource() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.OPENAI_API_KEY]
      hosts = ["api.openai.com"]
      from.env = "HOST_OPENAI_KEY"
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets[0].source, .env(name: "HOST_OPENAI_KEY"))
  }

  func testExplicitCommandSource() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.OPENAI_API_KEY]
      hosts = ["api.openai.com"]
      from.command = ["op", "read", "op://vault/openai"]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadLocal(from: path)
    XCTAssertEqual(manifest.secrets[0].source, .command(argv: ["op", "read", "op://vault/openai"]))
  }

  func testInvalidSourceWhenEnvAndCommandBothPresent() throws {
    let toml = """
      version = 0
      project = "test"

      [proxy.OPENAI_API_KEY]
      hosts = ["api.openai.com"]
      from.env = "HOST_OPENAI_KEY"
      from.command = ["op", "read", "op://vault/openai"]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadLocal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("exactly one"))
    }
  }

  func testGlobalManifestOmitsProject() throws {
    let toml = """
      version = 0

      [proxy.ANTHROPIC_API_KEY]
      hosts = ["api.anthropic.com"]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let manifest = try CredentialManifest.loadGlobal(from: path)
    XCTAssertEqual(manifest.project, "__global__")
  }

  func testGlobalManifestRejectsPassthrough() throws {
    let toml = """
      version = 0

      [passthrough.GITHUB_TOKEN]
      """
    let path = try writeTempTOML(toml)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try CredentialManifest.loadGlobal(from: path)) { error in
      XCTAssertTrue(String(describing: error).contains("only support [proxy.*]"))
    }
  }
}

private func writeTempTOML(_ content: String) throws -> String {
  let path = NSTemporaryDirectory() + "dvm-test-\(UUID().uuidString).toml"
  try content.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}
