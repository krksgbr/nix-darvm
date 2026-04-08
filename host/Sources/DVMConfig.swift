import Foundation
import TOML

/// User configuration loaded from ~/.config/dvm/config.toml.
///
/// Mount types:
///   mirror — mounted at the same absolute path in the guest (for project dirs)
///   home   — mounted relative to the guest user's home (for config/data dirs)
struct DVMConfig: Codable {
  var mounts: Mounts?
  /// Path to the user's dvm flake (fallback when no --flake flag or CWD flake).
  var flake: String?
  /// Port forwarding policy for dynamic auto-forwarding.
  var ports: Ports?

  struct Ports: Codable {
    /// Enable auto-forwarding of guest loopback listeners (default: true).
    var auto_forward: Bool?
    /// Inclusive port ranges to auto-forward, e.g. ["3000-5000"].
    var ranges: [String]?
    /// Explicit ports to auto-forward outside the ranges.
    var allow: [UInt16]?
  }

  struct MirrorMounts: Codable {
    var dirs: [String]
    var transport: MountTransport
  }

  struct HomeMounts: Codable {
    var dirs: [String]
  }

  struct Mounts: Codable {
    /// Directories mounted at their exact host path in the guest.
    /// Use for project directories where tools reference files by absolute path.
    var mirror: MirrorMounts?

    /// Directories mounted relative to the guest user's home.
    /// `~/.unison` on host → `/Users/admin/.unison` in guest.
    var home: HomeMounts?
  }

  var mirrorDirs: [String] { mounts?.mirror?.dirs ?? [] }
  var mirrorTransport: MountTransport? { mounts?.mirror?.transport }
  var homeDirs: [String] { mounts?.home?.dirs ?? [] }
  var portPolicy: PortPolicy { PortPolicy(from: ports) }

  static let empty = Self(mounts: nil, flake: nil, ports: nil)

  // Known keys per level — used to reject typos and misplaced keys.
  /// Load config from the default path. Returns empty config if file doesn't exist.
  /// Throws on parse errors so the user knows their config is broken.
  static func load() throws -> Self {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/dvm/config.toml").path

    guard FileManager.default.fileExists(atPath: path) else {
      return .empty
    }

    let contents = try String(contentsOfFile: path, encoding: .utf8)
    try validateKeys(contents)
    return try TOMLDecoder().decode(Self.self, from: contents)
  }

  /// Parse TOML as raw dictionary and reject unknown keys.
  private static func validateKeys(_ contents: String) throws {
    _ = try TOMLDecoder().decode(RawConfig.self, from: contents)
  }
}

private struct RawConfig: Decodable {
  var mounts: RawMounts?
  var flake: String?
  var ports: RawPorts?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try validateKeys(
      container.allKeys,
      known: knownTopLevelKeys,
      section: "top level"
    )
    mounts = try container.decodeIfPresent(RawMounts.self, forKey: .named("mounts"))
    flake = try container.decodeIfPresent(String.self, forKey: .named("flake"))
    ports = try container.decodeIfPresent(RawPorts.self, forKey: .named("ports"))
  }
}

private struct RawMounts: Decodable {
  var mirror: RawMirrorMounts?
  var home: RawHomeMounts?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try validateKeys(
      container.allKeys,
      known: knownMountsKeys,
      section: "mounts"
    )
    mirror = try container.decodeIfPresent(RawMirrorMounts.self, forKey: .named("mirror"))
    home = try container.decodeIfPresent(RawHomeMounts.self, forKey: .named("home"))
  }
}

private struct RawMirrorMounts: Decodable {
  var dirs: [String]
  var transport: MountTransport

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try validateKeys(
      container.allKeys,
      known: knownMirrorKeys,
      section: "mounts.mirror"
    )
    dirs = try container.decode([String].self, forKey: .named("dirs"))
    transport = try container.decode(MountTransport.self, forKey: .named("transport"))
  }
}

private struct RawHomeMounts: Decodable {
  var dirs: [String]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try validateKeys(
      container.allKeys,
      known: knownHomeKeys,
      section: "mounts.home"
    )
    dirs = try container.decode([String].self, forKey: .named("dirs"))
  }
}

private struct RawPorts: Decodable {
  var auto_forward: Bool?
  var ranges: [String]?
  var allow: [UInt16]?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try validateKeys(
      container.allKeys,
      known: knownPortsKeys,
      section: "ports"
    )
    auto_forward = try container.decodeIfPresent(Bool.self, forKey: .named("auto_forward"))
    ranges = try container.decodeIfPresent([String].self, forKey: .named("ranges"))
    allow = try container.decodeIfPresent([UInt16].self, forKey: .named("allow"))

    // Validate range format: each must be "NNN-MMM" with valid uint16 bounds.
    if let ranges {
      for range in ranges {
        let parts = range.split(separator: "-")
        guard parts.count == 2,
          let lo = UInt16(parts[0]),
          let hi = UInt16(parts[1]),
          lo > 0, lo <= hi
        else {
          throw ConfigError.invalidField(
            "Invalid range '\(range)' in [ports].ranges — expected \"LOW-HIGH\" (1-65535)")
        }
      }
    }

    // Reject port 0 in allow list.
    if let allow {
      for port in allow where port == 0 {
        throw ConfigError.invalidPort(port: 0)
      }
      let unique = Set(allow)
      if unique.count != allow.count {
        let duplicates = allow.filter { port in allow.filter { $0 == port }.count > 1 }
        throw ConfigError.duplicatePort(port: duplicates.first!)
      }
    }
  }
}

private let knownTopLevelKeys: Set<String> = ["flake", "mounts", "ports"]
private let knownMountsKeys: Set<String> = ["mirror", "home"]
private let knownMirrorKeys: Set<String> = ["dirs", "transport"]
private let knownHomeKeys: Set<String> = ["dirs"]
private let knownPortsKeys: Set<String> = ["auto_forward", "ranges", "allow"]

private struct DynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  private init(knownStringValue: String) {
    self.stringValue = knownStringValue
    self.intValue = nil
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue _: Int) {
    nil
  }

  static func named(_ stringValue: String) -> Self {
    Self(knownStringValue: stringValue)
  }
}

private func validateKeys(
  _ keys: [DynamicCodingKey],
  known: Set<String>,
  section: String
) throws {
  for key in keys where !known.contains(key.stringValue) {
    throw ConfigError.unknownKey(
      key: key.stringValue,
      section: section,
      known: known.sorted()
    )
  }
}
