import Foundation
import Security
import XCTest

@testable import dvm_core

// MARK: - Placeholder Derivation

final class PlaceholderDerivationTests: XCTestCase {

    let testKey = HostKey(bytes: Array(repeating: 0x42, count: 32))

    func testFormat() {
        let p = derivePlaceholder(project: "My Project", envVar: "API_KEY", hostKey: testKey)
        XCTAssertTrue(p.hasPrefix("SANDBOX_CRED_"))
        // Should contain slugified project and secret
        XCTAssertTrue(p.contains("my-project"), "Expected slugified project in: \(p)")
        XCTAssertTrue(p.contains("api-key"), "Expected slugified secret in: \(p)")
        // HMAC suffix: 16 hex chars
        let parts = p.split(separator: "_")
        let hmacSuffix = String(parts.last!)
        XCTAssertEqual(hmacSuffix.count, 16)
        XCTAssertTrue(hmacSuffix.allSatisfy { $0.isHexDigit })
    }

    func testDeterministic() {
        let p1 = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
        let p2 = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
        XCTAssertEqual(p1, p2)
    }

    func testDifferentProjectsDifferentPlaceholders() {
        let p1 = derivePlaceholder(project: "proj-a", envVar: "KEY", hostKey: testKey)
        let p2 = derivePlaceholder(project: "proj-b", envVar: "KEY", hostKey: testKey)
        XCTAssertNotEqual(p1, p2)
    }

    func testDifferentSecretsDifferentPlaceholders() {
        let p1 = derivePlaceholder(project: "proj", envVar: "KEY_A", hostKey: testKey)
        let p2 = derivePlaceholder(project: "proj", envVar: "KEY_B", hostKey: testKey)
        XCTAssertNotEqual(p1, p2)
    }

    func testDifferentKeysDifferentPlaceholders() {
        let key2 = HostKey(bytes: Array(repeating: 0x43, count: 32))
        let p1 = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: testKey)
        let p2 = derivePlaceholder(project: "proj", envVar: "KEY", hostKey: key2)
        XCTAssertNotEqual(p1, p2)
    }

    func testProjectNormalization() {
        // "My Project" and "  my project  " should produce the same placeholder
        let p1 = derivePlaceholder(project: "My Project", envVar: "KEY", hostKey: testKey)
        let p2 = derivePlaceholder(project: "  my project  ", envVar: "KEY", hostKey: testKey)
        XCTAssertEqual(p1, p2)
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

final class ManifestLoadTests: XCTestCase {

    func testValidManifest() throws {
        let toml = """
            version = 1
            project = "test-project"

            [proxy.API_KEY]
            hosts = ["api.example.com"]

            [proxy.OTHER_KEY]
            hosts = ["other.example.com", "api.example.com"]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.project, "test-project")
        XCTAssertEqual(manifest.secrets.count, 2)
        // Sorted by envVar
        XCTAssertEqual(manifest.secrets[0].envVar, "API_KEY")
        XCTAssertEqual(manifest.secrets[0].mode, .proxy)
        XCTAssertEqual(manifest.secrets[1].envVar, "OTHER_KEY")
        XCTAssertEqual(manifest.secrets[1].mode, .proxy)
    }

    func testMissingFile() {
        XCTAssertThrowsError(try CredentialManifest.load(from: "/nonexistent/path.toml")) { error in
            guard let e = error as? SecretConfigError else {
                return XCTFail("Expected SecretConfigError, got \(error)")
            }
            XCTAssertTrue(String(describing: e).contains("not found"))
        }
    }

    func testMalformedToml() {
        let path = writeTempTOML("this is not valid toml {{{")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path))
    }

    func testWrongVersion() {
        let toml = """
            version = 99
            project = "test"
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            XCTAssertTrue(String(describing: error).contains("version"))
        }
    }

    func testMissingProject() {
        let toml = """
            version = 1
            project = ""
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            XCTAssertTrue(String(describing: error).contains("project"))
        }
    }

    func testMissingProjectField() {
        // project field absent entirely (not just empty)
        let toml = """
            version = 1
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path))
    }

    func testWhitespaceOnlyProject() {
        let toml = """
            version = 1
            project = "   "
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            XCTAssertTrue(String(describing: error).contains("project"))
        }
    }

    func testEmptyHosts() {
        let toml = """
            version = 1
            project = "test"

            [proxy.KEY]
            hosts = []
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            XCTAssertTrue(String(describing: error).contains("empty"))
        }
    }

    func testWildcardHost() {
        let toml = """
            version = 1
            project = "test"

            [proxy.KEY]
            hosts = ["*.example.com"]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            XCTAssertTrue(String(describing: error).contains("wildcard"))
        }
    }

    func testHostsNormalized() throws {
        let toml = """
            version = 1
            project = "test"

            [proxy.KEY]
            hosts = ["API.Example.COM."]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.secrets[0].hosts, ["api.example.com"])
    }

    func testNoSecrets() throws {
        let toml = """
            version = 1
            project = "test"
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertTrue(manifest.secrets.isEmpty)
    }

    func testProjectNormalized() throws {
        let toml = """
            version = 1
            project = "  MY PROJECT  "
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.project, "my project")
    }

    func testSecretsSortedByEnvVar() throws {
        let toml = """
            version = 1
            project = "test"

            [proxy.ZEBRA]
            hosts = ["z.com"]

            [proxy.ALPHA]
            hosts = ["a.com"]

            [passthrough.MIDDLE]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.secrets.map(\.envVar), ["ALPHA", "MIDDLE", "ZEBRA"])
        XCTAssertEqual(manifest.secrets[0].mode, .proxy)
        XCTAssertEqual(manifest.secrets[1].mode, .passthrough)
        XCTAssertEqual(manifest.secrets[2].mode, .proxy)
    }

    func testPassthroughEntries() throws {
        let toml = """
            version = 1
            project = "test"

            [passthrough.DB_PASSWORD]
            [passthrough.AUTH_SECRET]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.secrets.count, 2)
        XCTAssertEqual(manifest.secrets[0].mode, .passthrough)
        XCTAssertEqual(manifest.secrets[0].hosts, [])
        XCTAssertEqual(manifest.secrets[1].mode, .passthrough)
        XCTAssertEqual(manifest.secrets[1].hosts, [])
    }

    func testDuplicateSecretAcrossTables() {
        let toml = """
            version = 1
            project = "test"

            [proxy.MY_KEY]
            hosts = ["example.com"]

            [passthrough.MY_KEY]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try CredentialManifest.load(from: path)) { error in
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("MY_KEY"), "Error should name the duplicate: \(desc)")
            XCTAssertTrue(desc.contains("both"), "Error should mention both tables: \(desc)")
        }
    }

    func testMixedProxyAndPassthrough() throws {
        let toml = """
            version = 1
            project = "test"

            [proxy.API_KEY]
            hosts = ["api.example.com"]

            [passthrough.DB_PASSWORD]
            """
        let path = writeTempTOML(toml)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manifest = try CredentialManifest.load(from: path)
        XCTAssertEqual(manifest.secrets.count, 2)
        let proxySecret = manifest.secrets.first { $0.envVar == "API_KEY" }!
        let passthroughSecret = manifest.secrets.first { $0.envVar == "DB_PASSWORD" }!
        XCTAssertEqual(proxySecret.mode, .proxy)
        XCTAssertEqual(proxySecret.hosts, ["api.example.com"])
        XCTAssertEqual(passthroughSecret.mode, .passthrough)
        XCTAssertEqual(passthroughSecret.hosts, [])
    }

    private func writeTempTOML(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "dvm-test-\(UUID().uuidString).toml"
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

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
        defer { unsetenv(var1); unsetenv(var2) }

        let manifest = CredentialManifest(
            version: 1,
            project: "test",
            secrets: [
                SecretDecl(envVar: var1, mode: .proxy, hosts: ["a.com"]),
                SecretDecl(envVar: var2, mode: .proxy, hosts: ["b.com"]),
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
        defer { unsetenv(proxyVar); unsetenv(ptVar) }

        let manifest = CredentialManifest(
            version: 1,
            project: "test",
            secrets: [
                SecretDecl(envVar: proxyVar, mode: .proxy, hosts: ["a.com"]),
                SecretDecl(envVar: ptVar, mode: .passthrough, hosts: []),
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
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("wrong size") || desc.contains("32"),
                          "Error should mention expected size: \(desc)")
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
        XCTAssertTrue(HostKey.keyPath.contains("/.config/dvm/"),
                       "Key path should be under ~/.config/dvm/, got: \(HostKey.keyPath)")
        XCTAssertFalse(HostKey.keyPath.contains("/.local/state/"),
                        "Key path must NOT be under ~/.local/state/: \(HostKey.keyPath)")
    }
}
