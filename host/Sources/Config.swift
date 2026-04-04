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

    static let empty = Self(mounts: nil, flake: nil)

    // Known keys per level — used to reject typos and misplaced keys.
    private static let knownTopLevel: Set<String> = ["flake", "mounts"]
    private static let knownMounts: Set<String> = ["mirror", "home"]
    private static let knownMirror: Set<String> = ["dirs", "transport"]
    private static let knownHome: Set<String> = ["dirs"]

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try DVMConfig.validate(
            keys: container.allKeys,
            known: DVMConfig.knownTopLevel,
            section: "top level"
        )
        mounts = try container.decodeIfPresent(RawMounts.self, forKey: .named("mounts"))
        flake = try container.decodeIfPresent(String.self, forKey: .named("flake"))
    }
}

private struct RawMounts: Decodable {
    var mirror: RawMirrorMounts?
    var home: RawHomeMounts?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try DVMConfig.validate(
            keys: container.allKeys,
            known: DVMConfig.knownMounts,
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
        try DVMConfig.validate(
            keys: container.allKeys,
            known: DVMConfig.knownMirror,
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
        try DVMConfig.validate(
            keys: container.allKeys,
            known: DVMConfig.knownHome,
            section: "mounts.home"
        )
        dirs = try container.decode([String].self, forKey: .named("dirs"))
    }
}

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

extension DVMConfig {
    fileprivate static func validate(
        keys: [DynamicCodingKey],
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
}
