import Foundation

/// Saved terminal state for raw mode restore.
struct TermState {
    fileprivate let termios: termios
}

/// Terminal utilities for TTY mode support.
enum Term {
    static func isTerminal() -> Bool {
        var t = termios()
        return tcgetattr(FileHandle.standardInput.fileDescriptor, &t) != -1
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
        var t = state.termios
        tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &t)
    }

    /// Get current terminal dimensions.
    static func getSize() throws -> (width: UInt16, height: UInt16) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != -1 else {
            throw TermError.operationFailed("failed to get terminal size: \(errnoMessage())")
        }
        return (width: ws.ws_col, height: ws.ws_row)
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
