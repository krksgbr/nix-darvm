import Darwin
import Foundation
import XCTest

@testable import dvm_core

final class VsockOwnedSocketTests: XCTestCase {
  func testDuplicateOwnedSocketDescriptorStaysValidAfterOriginalCloses() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    defer {
      for fd in fds where fd >= 0 {
        _ = Darwin.close(fd)
      }
    }

    let original = fds[0]
    let peer = fds[1]
    let duplicate = try duplicateOwnedSocketDescriptor(original)
    fds[0] = -1
    defer { _ = Darwin.close(duplicate) }

    XCTAssertEqual(Darwin.close(original), 0)

    var payload = Array("ping".utf8)
    let written = payload.withUnsafeMutableBytes { bytes in
      Darwin.write(peer, bytes.baseAddress, bytes.count)
    }
    XCTAssertEqual(written, payload.count)

    var received = [UInt8](repeating: 0, count: payload.count)
    let readCount = received.withUnsafeMutableBytes { bytes in
      Darwin.read(duplicate, bytes.baseAddress, bytes.count)
    }
    XCTAssertEqual(readCount, payload.count)
    XCTAssertEqual(received, payload)
  }

  func testDuplicateOwnedSocketDescriptorReportsBadFileDescriptor() {
    XCTAssertThrowsError(try duplicateOwnedSocketDescriptor(-1)) { error in
      guard let posixError = error as? POSIXError else {
        XCTFail("expected POSIXError, got \(error)")
        return
      }
      XCTAssertEqual(posixError.code, .EBADF)
    }
  }
}
