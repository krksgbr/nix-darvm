import Foundation
import XCTest

@testable import dvm_core

/// Tests for credential manifest discovery chain:
/// `--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd.
///
/// These tests mutate the process-global `DVM_CREDENTIALS` env var and must run
/// serially (the default for XCTest in SwiftPM).
final class DiscoveryTests: XCTestCase {

    var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "dvm-discovery-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        // Always clean up the env var
        unsetenv("DVM_CREDENTIALS")
        super.tearDown()
    }

    // MARK: - No manifest (silent skip)

    func testNoManifest_returnsNil() throws {
        // Empty directory, no flag, no env var
        unsetenv("DVM_CREDENTIALS")
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        XCTAssertNil(path)
    }

    // MARK: - CWD discovery

    func testCwdDiscovery_findsManifest() throws {
        let dvmDir = tempDir + "/.dvm"
        try FileManager.default.createDirectory(
            atPath: dvmDir, withIntermediateDirectories: true)
        let manifestPath = dvmDir + "/credentials.toml"
        try "version = 1\nproject = \"test\"".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        unsetenv("DVM_CREDENTIALS")
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        XCTAssertEqual(path, manifestPath)
    }

    func testCwdDiscovery_noWalking() throws {
        // Put manifest in parent, but cwd is a child — should NOT find it
        let parentDir = tempDir!
        let childDir = parentDir + "/child"
        try FileManager.default.createDirectory(
            atPath: childDir, withIntermediateDirectories: true)

        let dvmDir = parentDir + "/.dvm"
        try FileManager.default.createDirectory(
            atPath: dvmDir, withIntermediateDirectories: true)
        try "version = 1\nproject = \"test\"".write(
            toFile: dvmDir + "/credentials.toml", atomically: true, encoding: .utf8)

        unsetenv("DVM_CREDENTIALS")
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: childDir)
        XCTAssertNil(path, "Should not walk up to parent directory")
    }

    // MARK: - --credentials flag

    func testFlag_absolutePath() throws {
        let manifestPath = tempDir + "/custom.toml"
        try "version = 1\nproject = \"test\"".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        let path = try discoverManifestPath(credentialsFlag: manifestPath, cwd: "/tmp")
        XCTAssertEqual(path, manifestPath)
    }

    func testFlag_relativePath() throws {
        let manifestPath = tempDir + "/custom.toml"
        try "version = 1\nproject = \"test\"".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        // Relative to cwd
        let path = try discoverManifestPath(credentialsFlag: "custom.toml", cwd: tempDir)
        XCTAssertEqual(path, manifestPath)
    }

    func testFlag_missingFile_throws() {
        XCTAssertThrowsError(
            try discoverManifestPath(
                credentialsFlag: "/nonexistent/manifest.toml", cwd: tempDir)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("not found"))
        }
    }

    func testFlag_takesPriorityOverCwd() throws {
        // Both CWD and flag manifest exist — flag wins
        let dvmDir = tempDir + "/.dvm"
        try FileManager.default.createDirectory(
            atPath: dvmDir, withIntermediateDirectories: true)
        try "version = 1\nproject = \"cwd-project\"".write(
            toFile: dvmDir + "/credentials.toml", atomically: true, encoding: .utf8)

        let flagManifest = tempDir + "/flag-manifest.toml"
        try "version = 1\nproject = \"flag-project\"".write(
            toFile: flagManifest, atomically: true, encoding: .utf8)

        let path = try discoverManifestPath(credentialsFlag: flagManifest, cwd: tempDir)
        XCTAssertEqual(path, flagManifest)
    }

    func testFlag_takesPriorityOverEnvVar() throws {
        let flagManifest = tempDir + "/flag.toml"
        try "version = 1\nproject = \"flag\"".write(
            toFile: flagManifest, atomically: true, encoding: .utf8)

        let envManifest = tempDir + "/env.toml"
        try "version = 1\nproject = \"env\"".write(
            toFile: envManifest, atomically: true, encoding: .utf8)

        setenv("DVM_CREDENTIALS", envManifest, 1)
        let path = try discoverManifestPath(credentialsFlag: flagManifest, cwd: tempDir)
        XCTAssertEqual(path, flagManifest)
    }

    // MARK: - DVM_CREDENTIALS env var

    func testEnvVar_absolutePath() throws {
        let manifestPath = tempDir + "/env-manifest.toml"
        try "version = 1\nproject = \"test\"".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        setenv("DVM_CREDENTIALS", manifestPath, 1)
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: "/tmp")
        XCTAssertEqual(path, manifestPath)
    }

    func testEnvVar_relativePath() throws {
        let manifestPath = tempDir + "/env-manifest.toml"
        try "version = 1\nproject = \"test\"".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        setenv("DVM_CREDENTIALS", "env-manifest.toml", 1)
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        XCTAssertEqual(path, manifestPath)
    }

    func testEnvVar_empty_throws() {
        setenv("DVM_CREDENTIALS", "", 1)
        XCTAssertThrowsError(
            try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("empty"))
        }
    }

    func testEnvVar_missingFile_throws() {
        setenv("DVM_CREDENTIALS", "/nonexistent/path.toml", 1)
        XCTAssertThrowsError(
            try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("not found"))
        }
    }

    func testEnvVar_takesPriorityOverCwd() throws {
        // Both CWD and env var manifest exist — env var wins
        let dvmDir = tempDir + "/.dvm"
        try FileManager.default.createDirectory(
            atPath: dvmDir, withIntermediateDirectories: true)
        try "version = 1\nproject = \"cwd\"".write(
            toFile: dvmDir + "/credentials.toml", atomically: true, encoding: .utf8)

        let envManifest = tempDir + "/env-manifest.toml"
        try "version = 1\nproject = \"env\"".write(
            toFile: envManifest, atomically: true, encoding: .utf8)

        setenv("DVM_CREDENTIALS", envManifest, 1)
        let path = try discoverManifestPath(credentialsFlag: nil, cwd: tempDir)
        XCTAssertEqual(path, envManifest)
    }
}
