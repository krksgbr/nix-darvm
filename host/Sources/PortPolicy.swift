/// Determines which guest loopback ports the host should auto-forward.
///
/// Built from the `[ports]` section of `~/.config/dvm/config.toml`.
/// When no config is present, defaults to auto-forwarding common dev ports.
struct PortPolicy: Sendable {
  let autoForward: Bool
  let ranges: [ClosedRange<UInt16>]
  let allow: Set<UInt16>

  static let defaultRanges: [ClosedRange<UInt16>] = [3_000...5_000]
  static let defaultAllow: Set<UInt16> = [5_432, 6_379, 8_000, 8_080, 8_081, 9_000]

  static let `default` = Self(
    autoForward: true,
    ranges: defaultRanges,
    allow: defaultAllow
  )

  static let disabled = Self(
    autoForward: false,
    ranges: [],
    allow: []
  )

  init(autoForward: Bool, ranges: [ClosedRange<UInt16>], allow: Set<UInt16>) {
    self.autoForward = autoForward
    self.ranges = ranges
    self.allow = allow
  }

  /// Build from the `[ports]` config section.
  /// No `[ports]` section → defaults. `auto_forward = false` → disabled.
  /// User-supplied `ranges`/`allow` replace defaults (not merge).
  init(from ports: DVMConfig.Ports?) {
    guard let ports else {
      self = .default
      return
    }

    let auto = ports.autoForward
    guard auto else {
      self = .disabled
      return
    }

    self.autoForward = true
    self.ranges = (ports.ranges ?? Self.defaultRanges.map(Self.formatRange))
      .compactMap(Self.parseRange)
    self.allow = ports.allow.map(Set.init) ?? Self.defaultAllow
  }

  private static func parseRange(_ rangeString: String) -> ClosedRange<UInt16>? {
    let parts = rangeString.split(separator: "-")
    guard parts.count == 2,
      let loBound = UInt16(parts[0]),
      let hiBound = UInt16(parts[1]),
      loBound > 0, loBound <= hiBound
    else {
      return nil
    }
    return loBound...hiBound
  }

  private static func formatRange(_ range: ClosedRange<UInt16>) -> String {
    "\(range.lowerBound)-\(range.upperBound)"
  }

  func isAllowed(_ port: UInt16) -> Bool {
    if allow.contains(port) {
      return true
    }
    return ranges.contains { $0.contains(port) }
  }
}
