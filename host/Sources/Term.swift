import Foundation

/// Saved terminal state for raw mode restore.
struct TermState {
  fileprivate let termios: termios
}

/// Terminal utilities for TTY mode support.
enum Term {
  static func isTerminal() -> Bool {
    var terminalAttributes = termios()
    return tcgetattr(FileHandle.standardInput.fileDescriptor, &terminalAttributes) != -1
  }

  /// Switch the terminal to raw mode. Returns the previous state for restore.
  static func makeRaw() throws -> TermState {
    var orig = termios()
    guard tcgetattr(FileHandle.standardInput.fileDescriptor, &orig) != -1 else {
      throw TermError.operationFailed("failed to get terminal attributes: \(errnoMessage())")
    }

    var raw = orig
    cfmakeraw(&raw)

    guard tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &raw) != -1 else {
      throw TermError.operationFailed("failed to set raw mode: \(errnoMessage())")
    }

    return TermState(termios: orig)
  }

  /// Restore terminal to a previously saved state.
  static func restore(_ state: TermState) {
    var terminalAttributes = state.termios
    tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &terminalAttributes)
  }

  /// Get current terminal dimensions.
  static func getSize() throws -> (width: UInt16, height: UInt16) {
    var windowSize = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) != -1 else {
      throw TermError.operationFailed("failed to get terminal size: \(errnoMessage())")
    }
    return (width: windowSize.ws_col, height: windowSize.ws_row)
  }
}

private func errnoMessage() -> String {
  String(cString: strerror(errno))
}

enum TermError: Error, CustomStringConvertible {
  case operationFailed(String)

  var description: String {
    switch self {
    case .operationFailed(let msg): return msg
    }
  }
}
