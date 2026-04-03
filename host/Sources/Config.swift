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

  static let empty = DVMConfig(mounts: nil, flake: nil)

  // Known keys per level — used to reject typos and misplaced keys.
  private static let knownTopLevel: Set<String> = ["flake", "mounts"]
  private static let knownMounts: Set<String> = ["mirror", "home"]
  private static let knownMirror: Set<String> = ["dirs", "transport"]
  private static let knownHome: Set<String> = ["dirs"]

  /// Load config from the default path. Returns empty config if file doesn't exist.
  /// Throws on parse errors so the user knows their config is broken.
  static func load() throws -> DVMConfig {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/dvm/config.toml").path

    guard FileManager.default.fileExists(atPath: path) else {
      return .empty
    }

    let contents = try String(contentsOfFile: path, encoding: .utf8)
    try validateKeys(contents, path: path)
    return try TOMLDecoder().decode(DVMConfig.self, from: contents)
  }

  /// Parse TOML as raw dictionary and reject unknown keys.
  private static func validateKeys(_ contents: String, path: String) throws {
    // TOMLDecoder can decode to a [String: Any]-like structure via
    // a wrapper type. Simpler: just use the same decoder with a
    // loose type to extract top-level keys.
    struct RawConfig: Decodable {
      struct RawMirrorMounts: Decodable {
        var dirs: [String]
        var transport: MountTransport

        struct CodingKeys: CodingKey {
          var stringValue: String
          var intValue: Int?
          init?(stringValue: String) { self.stringValue = stringValue }
          init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)
          for key in container.allKeys where !DVMConfig.knownMirror.contains(key.stringValue) {
            throw ConfigError.unknownKey(
              key: key.stringValue, section: "mounts.mirror",
              known: DVMConfig.knownMirror.sorted())
          }
          dirs = try container.decode(
            [String].self,
            forKey: CodingKeys(stringValue: "dirs")!)
          transport = try container.decode(
            MountTransport.self,
            forKey: CodingKeys(stringValue: "transport")!)
        }
      }

      struct RawHomeMounts: Decodable {
        var dirs: [String]

        struct CodingKeys: CodingKey {
          var stringValue: String
          var intValue: Int?
          init?(stringValue: String) { self.stringValue = stringValue }
          init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)
          for key in container.allKeys where !DVMConfig.knownHome.contains(key.stringValue) {
            throw ConfigError.unknownKey(
              key: key.stringValue, section: "mounts.home",
              known: DVMConfig.knownHome.sorted())
          }
          dirs = try container.decode(
            [String].self,
            forKey: CodingKeys(stringValue: "dirs")!)
        }
      }

      struct RawMounts: Decodable {
        // Accept known keys, catch unknown via CodingKeys
        var mirror: RawMirrorMounts?
        var home: RawHomeMounts?

        struct CodingKeys: CodingKey {
          var stringValue: String
          var intValue: Int?
          init?(stringValue: String) { self.stringValue = stringValue }
          init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)
          for key in container.allKeys where !DVMConfig.knownMounts.contains(key.stringValue) {
            throw ConfigError.unknownKey(
              key: key.stringValue, section: "mounts",
              known: DVMConfig.knownMounts.sorted())
          }
          mirror = try container.decodeIfPresent(
            RawMirrorMounts.self,
            forKey: CodingKeys(stringValue: "mirror")!)
          home = try container.decodeIfPresent(
            RawHomeMounts.self,
            forKey: CodingKeys(stringValue: "home")!)
        }
      }

      var mounts: RawMounts?
      var flake: String?

      struct CodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in container.allKeys where !DVMConfig.knownTopLevel.contains(key.stringValue) {
          throw ConfigError.unknownKey(
            key: key.stringValue, section: "top level",
            known: DVMConfig.knownTopLevel.sorted())
        }
        mounts = try container.decodeIfPresent(
          RawMounts.self,
          forKey: CodingKeys(stringValue: "mounts")!)
        flake = try container.decodeIfPresent(
          String.self,
          forKey: CodingKeys(stringValue: "flake")!)
      }
    }

    _ = try TOMLDecoder().decode(RawConfig.self, from: contents)
  }
}
