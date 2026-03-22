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

    struct Mounts: Codable {
        /// Directories mounted at their exact host path in the guest.
        /// Use for project directories where tools reference files by absolute path.
        var mirror: [String]?

        /// Directories mounted relative to the guest user's home.
        /// `~/.unison` on host → `/Users/admin/.unison` in guest.
        var home: [String]?
    }

    var mirrorDirs: [String] { mounts?.mirror ?? [] }
    var homeDirs: [String] { mounts?.home ?? [] }

    static let empty = DVMConfig(mounts: nil, flake: nil)

    /// Load config from the default path. Returns empty config if file doesn't exist.
    /// Throws on parse errors so the user knows their config is broken.
    static func load() throws -> DVMConfig {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dvm/config.toml").path

        guard FileManager.default.fileExists(atPath: path) else {
            return .empty
        }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return try TOMLDecoder().decode(DVMConfig.self, from: contents)
    }

}
