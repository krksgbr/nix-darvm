import Darwin
import Foundation

/// Renders dvm-netstack terminal output through the host process so the host
/// owns the live terminal stream. Consecutive identical lines are summarized
/// instead of printed repeatedly, while raw diagnostics remain in the sidecar's
/// dedicated raw log file.
final class NetstackTerminalRenderer: @unchecked Sendable {
  private let lock = NSLock()
  private let emitLine: @Sendable (String) -> Void
  private let replaceLiveLine: @Sendable (String) -> Void
  private let commitLiveLine: @Sendable () -> Void
  private let supportsLiveUpdates: Bool

  private var buffer = ""
  private var lastLine: String?
  private var lastCollapseKey: String?
  private var lastLineCount = 0

  private static func collapseKey(for line: String) -> String {
    let prefix = " dvm-netstack: "
    guard line.count > 8 + prefix.count else {
      return line
    }

    let timestamp = line.prefix(8)
    guard isClockTimestamp(timestamp) else {
      return line
    }

    let remainder = line.dropFirst(8)
    guard remainder.hasPrefix(prefix) else {
      return line
    }

    return String(remainder.dropFirst(prefix.count))
  }

  private static func isClockTimestamp<S: StringProtocol>(_ value: S) -> Bool {
    guard value.count == 8 else {
      return false
    }

    let characters = Array(value)
    return characters[0].isNumber
      && characters[1].isNumber
      && characters[2] == ":"
      && characters[3].isNumber
      && characters[4].isNumber
      && characters[5] == ":"
      && characters[6].isNumber
      && characters[7].isNumber
  }

  init(
    emitLine: @escaping @Sendable (String) -> Void = consolePrintLine,
    replaceLiveLine: @escaping @Sendable (String) -> Void = consoleReplaceLiveLine,
    commitLiveLine: @escaping @Sendable () -> Void = consoleCommitLiveLine,
    supportsLiveUpdates: Bool = isatty(STDOUT_FILENO) == 1
  ) {
    self.emitLine = emitLine
    self.replaceLiveLine = replaceLiveLine
    self.commitLiveLine = commitLiveLine
    self.supportsLiveUpdates = supportsLiveUpdates
  }

  func append(_ data: Data) {
    guard let text = String(bytes: data, encoding: .utf8) else {
      return
    }
    append(text)
  }

  func append(_ text: String) {
    lock.lock()
    defer { lock.unlock() }

    buffer += text
    var lines = buffer.components(separatedBy: "\n")
    buffer = lines.removeLast()
    for line in lines {
      processLine(String(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))))
    }
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }

    if !buffer.isEmpty {
      processLine(buffer)
      buffer = ""
    }
    flushRepeatSummaryIfNeeded()
  }

  private func processLine(_ line: String) {
    let collapseKey = Self.collapseKey(for: line)
    if collapseKey == lastCollapseKey {
      lastLineCount += 1
      refreshLiveLineIfNeeded()
      return
    }

    flushRepeatSummaryIfNeeded()
    renderNewCurrentLine(line, collapseKey: collapseKey)
  }

  private func flushRepeatSummaryIfNeeded() {
    guard lastLine != nil else {
      return
    }

    if supportsLiveUpdates {
      commitLiveLine()
    } else if let lastLine, lastLineCount > 1 {
      emitLine("\(lastLine) [x\(lastLineCount)]")
    }

    self.lastLine = nil
    lastCollapseKey = nil
    lastLineCount = 0
  }

  private func renderNewCurrentLine(_ line: String, collapseKey: String) {
    if supportsLiveUpdates {
      replaceLiveLine(line)
    } else {
      emitLine(line)
    }

    lastLine = line
    lastCollapseKey = collapseKey
    lastLineCount = 1
  }

  private func refreshLiveLineIfNeeded() {
    guard supportsLiveUpdates, let lastLine else {
      return
    }

    let renderedLine = lastLineCount > 1 ? "\(lastLine) [x\(lastLineCount)]" : lastLine
    replaceLiveLine(renderedLine)
  }
}
