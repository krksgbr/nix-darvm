import Foundation
import XCTest

@testable import dvm_core

final class NetstackTerminalRendererTests: XCTestCase {
  func testSingleLineRendersImmediately() {
    let recorder = Recorder()
    let renderer = NetstackTerminalRenderer { recorder.append($0) }

    renderer.append("18:39:25 dvm-netstack: network stack running\n")
    renderer.finish()

    XCTAssertEqual(recorder.lines, ["18:39:25 dvm-netstack: network stack running"])
  }

  func testRepeatedIdenticalLinesEmitCollapsedSummaryWhenLineChanges() {
    let recorder = Recorder()
    let renderer = NetstackTerminalRenderer { recorder.append($0) }

    renderer.append("same\nsame\nsame\nnext\n")
    renderer.finish()

    XCTAssertEqual(recorder.lines, ["same", "same [x3]", "next"])
  }

  func testRepeatedIdenticalLinesFlushCollapsedSummaryOnFinish() {
    let recorder = Recorder()
    let renderer = NetstackTerminalRenderer { recorder.append($0) }

    renderer.append("same\nsame\n")
    renderer.finish()

    XCTAssertEqual(recorder.lines, ["same", "same [x2]"])
  }
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(line)
  }
}
