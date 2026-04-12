import XCTest

@testable import dvm_core

final class ConsoleStyleTests: XCTestCase {
  func testDisabledLeavesMessagePlain() {
    XCTAssertEqual(
      ConsoleStyle.renderMessage("VM reachable at 172.22.0.2", enabled: false),
      "VM reachable at 172.22.0.2"
    )
  }

  func testSuccessToneGetsColored() {
    let rendered = ConsoleStyle.renderMessage("Guest agent connected.", tone: .success, enabled: true)
    XCTAssertTrue(rendered.contains("\u{001B}[32m"))
    XCTAssertTrue(rendered.contains("Guest agent connected."))
  }

  func testPlainToneDoesNotInferWarningFromWording() {
    let rendered = ConsoleStyle.renderMessage("Warning: copy changed", tone: .plain, enabled: true)
    XCTAssertFalse(rendered.contains("\u{001B}[33m"))
    XCTAssertTrue(rendered.hasSuffix("Warning: copy changed"))
  }

  func testSourcePathIPAndRunIDGetHighlighted() {
    let rendered = ConsoleStyle.renderMessage(
      "[activator] starting (run: rso8ev9x, closure: /nix/store/example) VM reachable at 172.22.0.2",
      enabled: true
    )

    XCTAssertTrue(rendered.contains("\u{001B}[36m[activator]\u{001B}[0m"))
    XCTAssertTrue(rendered.contains("\u{001B}[35mrso8ev9x\u{001B}[0m"))
    XCTAssertTrue(rendered.contains("\u{001B}[34m/nix/store/example\u{001B}[0m"))
    XCTAssertTrue(rendered.contains("\u{001B}[36m172.22.0.2\u{001B}[0m"))
  }

  func testTimestampGetsDimmed() {
    let rendered = ConsoleStyle.formatTimestampedMessage(
      elapsed: 33.314,
      message: "Mounting runtime shares...",
      enabled: true
    )

    XCTAssertTrue(rendered.hasPrefix("\u{001B}[2m["))
    XCTAssertTrue(rendered.contains("]\u{001B}[0m "))
    XCTAssertTrue(rendered.contains(":"))
  }

  func testMITMCALineStaysUncoloredApartFromTimestamp() {
    let rendered = ConsoleStyle.formatTimestampedMessage(
      elapsed: 33.796,
      message: "MITM CA installed in guest trust store.",
      enabled: true
    )

    XCTAssertFalse(rendered.contains("\u{001B}[32mMITM CA installed in guest trust store.\u{001B}[0m"))
    XCTAssertTrue(rendered.hasSuffix("MITM CA installed in guest trust store."))
  }
}
