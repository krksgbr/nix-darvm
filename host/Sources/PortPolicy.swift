/// Determines which guest loopback ports the host should auto-forward.
///
/// Built from the `[ports]` section of `~/.config/dvm/config.toml`.
/// When no config is present, defaults to auto-forwarding common dev ports.
struct PortPolicy: Sendable {
  let autoForward: Bool
  let ranges: [ClosedRange<UInt16>]
  let allow: Set<UInt16>

  static let defaultRanges: [ClosedRange<UInt16>] = [3000...5000]
  static let defaultAllow: Set<UInt16> = [5432, 6379, 8000, 8080, 8081, 9000]

  static let `default` = PortPolicy(
    autoForward: true,
    ranges: defaultRanges,
    allow: defaultAllow
  )

  static let disabled = PortPolicy(
    autoForward: false,
    ranges: [],
    allow: []
  )

  init(autoForward: Bool, ranges: [ClosedRange<UInt16>], allow: Set<UInt16>) {
    self.autoForward = autoForward
    self.ranges = ranges
    self.allow = allow
  }

  func isAllowed(_ port: UInt16) -> Bool {
    if allow.contains(port) { return true }
    return ranges.contains { $0.contains(port) }
  }

  /// Build from the `[ports]` config section.
  /// No `[ports]` section → defaults. `auto_forward = false` → disabled.
  /// User-supplied `ranges`/`allow` replace defaults (not merge).
  init(from ports: DVMConfig.Ports?) {
    guard let ports else {
      self = .default
      return
    }

    let auto = ports.auto_forward ?? true
    guard auto else {
      self = .disabled
      return
    }

    self.autoForward = true
    self.ranges = (ports.ranges ?? Self.defaultRanges.map(Self.formatRange))
      .compactMap(Self.parseRange)
    self.allow = ports.allow.map(Set.init) ?? Self.defaultAllow
  }

  private static func parseRange(_ s: String) -> ClosedRange<UInt16>? {
    let parts = s.split(separator: "-")
    guard parts.count == 2,
      let lo = UInt16(parts[0]),
      let hi = UInt16(parts[1]),
      lo > 0, lo <= hi
    else { return nil }
    return lo...hi
  }

  private static func formatRange(_ range: ClosedRange<UInt16>) -> String {
    "\(range.lowerBound)-\(range.upperBound)"
  }
}
