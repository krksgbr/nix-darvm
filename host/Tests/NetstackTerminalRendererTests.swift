import Foundation
import XCTest

@testable import dvm_core

final class NetstackTerminalRendererTests: XCTestCase {
  func testSingleLineRendersImmediatelyWithoutLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: false)

    renderer.append("18:39:25 dvm-netstack: network stack running\n")
    renderer.finish()

    XCTAssertEqual(recorder.events, [.line("18:39:25 dvm-netstack: network stack running")])
  }

  func testRepeatedIdenticalLinesEmitCollapsedSummaryWhenLineChangesWithoutLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: false)

    renderer.append("same\nsame\nsame\nnext\n")
    renderer.finish()

    XCTAssertEqual(recorder.events, [.line("same"), .line("same [x3]"), .line("next")])
  }

  func testRepeatedIdenticalLinesFlushCollapsedSummaryOnFinishWithoutLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: false)

    renderer.append("same\nsame\n")
    renderer.finish()

    XCTAssertEqual(recorder.events, [.line("same"), .line("same [x2]")])
  }

  func testNetstackLinesCollapseAcrossTimestampChangesWithoutLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: false)

    renderer.append(
      """
      11:14:28 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF
      11:14:29 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF
      11:14:30 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF
      11:14:31 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF
      """
    )
    renderer.finish()

    XCTAssertEqual(
      recorder.events,
      [
        .line("11:14:28 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF"),
        .line(
          "11:14:28 dvm-netstack: https: TLS handshake failed for api.openai.com: read buffered connection: EOF [x4]")
      ]
    )
  }

  func testDifferentNetstackMessagesDoNotCollapseTogetherWithoutLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: false)

    renderer.append(
      """
      11:14:28 dvm-netstack: first message
      11:14:29 dvm-netstack: second message
      """
    )
    renderer.finish()

    XCTAssertEqual(
      recorder.events,
      [
        .line("11:14:28 dvm-netstack: first message"),
        .line("11:14:29 dvm-netstack: second message")
      ]
    )
  }

  func testRepeatedLinesUpdateInPlaceWithLiveUpdates() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: true)

    renderer.append("same\nsame\nsame\n")
    renderer.finish()

    XCTAssertEqual(
      recorder.events,
      [
        .replace("same"),
        .replace("same [x2]"),
        .replace("same [x3]"),
        .commit
      ]
    )
  }

  func testLiveUpdatesCommitBeforeSwitchingToNextMessage() {
    let recorder = Recorder()
    let renderer = makeRenderer(recorder: recorder, supportsLiveUpdates: true)

    renderer.append("same\nsame\nnext\n")
    renderer.finish()

    XCTAssertEqual(
      recorder.events,
      [
        .replace("same"),
        .replace("same [x2]"),
        .commit,
        .replace("next"),
        .commit
      ]
    )
  }

  private func makeRenderer(recorder: Recorder, supportsLiveUpdates: Bool) -> NetstackTerminalRenderer {
    NetstackTerminalRenderer(
      emitLine: { recorder.record(.line($0)) },
      replaceLiveLine: { recorder.record(.replace($0)) },
      commitLiveLine: { recorder.record(.commit) },
      supportsLiveUpdates: supportsLiveUpdates
    )
  }
}

private final class Recorder: @unchecked Sendable {
  enum Event: Equatable {
    case line(String)
    case replace(String)
    case commit
  }

  private let lock = NSLock()
  private var storage: [Event] = []

  var events: [Event] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func record(_ event: Event) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(event)
  }
}
