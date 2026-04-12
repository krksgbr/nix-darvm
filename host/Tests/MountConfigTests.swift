import XCTest

@testable import dvm_core

final class MountConfigTests: XCTestCase {
  func testBuildMounts_onlyNixStoreIsBuiltInByDefault() throws {
    let mounts = try buildMounts(
      hostHome: "/Users/tester",
      mirrorDirs: [],
      mirrorTransport: nil,
      homeDirs: []
    )

    XCTAssertEqual(mounts.map(\.tag.rawValue), ["nix-store"])
    XCTAssertEqual(mounts.filter(\.isBuiltIn).map(\.tag.rawValue), ["nix-store"])
  }

  func testBuildMounts_doesNotMountHostNixCacheByDefault() throws {
    let mounts = try buildMounts(
      hostHome: "/Users/tester",
      mirrorDirs: [],
      mirrorTransport: nil,
      homeDirs: []
    )

    XCTAssertFalse(mounts.contains { $0.guestPath.rawValue == "/Users/admin/.cache/nix" })
    XCTAssertFalse(mounts.contains { $0.hostPath.rawValue == "/Users/tester/.cache/nix" })
  }

  func testBuildMounts_rejectsSharedCacheHomeMount() {
    XCTAssertThrowsError(
      try buildMounts(
        hostHome: "/Users/tester",
        mirrorDirs: [],
        mirrorTransport: nil,
        homeDirs: ["/Users/tester/.cache/nix"]
      )
    ) { error in
      XCTAssertTrue(String(describing: error).contains("'.cache/nix' is reserved"))
    }
  }
}
