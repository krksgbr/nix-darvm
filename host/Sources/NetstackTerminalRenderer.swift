import Foundation

/// Renders dvm-netstack terminal output through the host process so the host
/// owns the live terminal stream. Consecutive identical lines are summarized
/// instead of printed repeatedly, while raw diagnostics remain in the sidecar's
/// dedicated raw log file.
final class NetstackTerminalRenderer: @unchecked Sendable {
  private let lock = NSLock()
  private let emit: @Sendable (String) -> Void

  private var buffer = ""
  private var lastLine: String?
  private var lastLineCount = 0

  init(emit: @escaping @Sendable (String) -> Void = consolePrintLine) {
    self.emit = emit
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
    if line == lastLine {
      lastLineCount += 1
      return
    }

    flushRepeatSummaryIfNeeded()
    emit(line)
    lastLine = line
    lastLineCount = 1
  }

  private func flushRepeatSummaryIfNeeded() {
    guard let lastLine, lastLineCount > 1 else {
      return
    }

    emit("\(lastLine) [x\(lastLineCount)]")
    self.lastLine = nil
    lastLineCount = 0
  }
}
