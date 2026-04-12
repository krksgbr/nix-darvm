import Darwin
import Foundation

enum ConsoleTone {
  case plain
  case success
  case warning
  case error
}

enum ConsoleStyle {
  private enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
  }

  static var isStdoutEnabled: Bool {
    getenv("NO_COLOR") == nil && isatty(STDOUT_FILENO) == 1
  }

  static func formatTimestampedMessage(
    elapsed: CFAbsoluteTime,
    message: String,
    tone: ConsoleTone = .plain,
    enabled: Bool = ConsoleStyle.isStdoutEnabled
  ) -> String {
    let secs = Int(elapsed)
    let milliseconds = Int((elapsed - Double(secs)) * 1_000)
    let timestamp = String(format: "[%3d.%03ds]", secs, milliseconds)
    let renderedTimestamp = enabled ? wrap(timestamp, ANSI.dim) : timestamp
    return "\(renderedTimestamp) \(renderMessage(message, tone: tone, enabled: enabled))"
  }

  static func renderMessage(
    _ message: String,
    tone: ConsoleTone = .plain,
    enabled: Bool = ConsoleStyle.isStdoutEnabled
  ) -> String {
    guard enabled else {
      return message
    }

    var rendered = message
    rendered = replaceMatches(in: rendered, pattern: #"^\[[^\]]+\]"#, style: ANSI.bold + ANSI.cyan)
    rendered = replaceMatches(in: rendered, pattern: #"'\[[^\]]+\]'"#, style: ANSI.bold + ANSI.cyan)
    rendered = replaceMatches(in: rendered, pattern: #"(?<=\brun: )[A-Za-z0-9-]+|(?<=\brun_id=)[A-Za-z0-9-]+"#, style: ANSI.bold + ANSI.magenta)
    rendered = replaceMatches(in: rendered, pattern: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, style: ANSI.bold + ANSI.cyan)
    rendered = replaceMatches(in: rendered, pattern: #"/(?:[^\s,)']+)"#, style: ANSI.blue)
    rendered = replaceMatches(in: rendered, pattern: #"\b(->|\(--flake flag\)|\(current directory\)|\(config\.toml\))\b"#, style: ANSI.dim)

    switch tone {
    case .plain:
      return rendered
    case .success:
      return wrap(rendered, ANSI.bold + ANSI.green)
    case .warning:
      return wrap(rendered, ANSI.bold + ANSI.yellow)
    case .error:
      return wrap(rendered, ANSI.bold + ANSI.red)
    }
  }

  private static func replaceMatches(in message: String, pattern: String, style: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return message
    }

    let range = NSRange(message.startIndex..<message.endIndex, in: message)
    let matches = regex.matches(in: message, range: range)
    guard !matches.isEmpty else {
      return message
    }

    var rendered = message
    for match in matches.reversed() {
      guard let swiftRange = Range(match.range, in: rendered) else {
        continue
      }
      let original = String(rendered[swiftRange])
      rendered.replaceSubrange(swiftRange, with: wrap(original, style))
    }

    return rendered
  }

  private static func wrap(_ text: String, _ style: String) -> String {
    "\(style)\(text)\(ANSI.reset)"
  }
}
