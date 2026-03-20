import Foundation
import TOML

/// User configuration loaded from ~/.config/dvm/config.toml.
///
/// WARNING: Do NOT mount ~/.config/dvm in the guest VM (neither as mirror nor home).
/// This file contains the host command allowlist ([host].commands). If a rogue guest
/// process can write to it, it can add arbitrary commands and gain host execution
/// on the next VM restart. TODO: migrate to nix config (nix-darvm-xuus).
///
/// Mount types:
///   mirror — mounted at the same absolute path in the guest (for project dirs)
///   home   — mounted relative to the guest user's home (for config/data dirs)
struct DVMConfig: Codable {
    var mounts: Mounts?
    var host: Host?
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

    struct Host: Codable {
        /// Commands forwarded from guest to host via vsock.
        /// Each command gets a symlink in the guest pointing to dvm-host-cmd.
        var commands: [String]?
    }

    var mirrorDirs: [String] { mounts?.mirror ?? [] }
    var homeDirs: [String] { mounts?.home ?? [] }
    var hostCommands: [String] { host?.commands ?? [] }

    static let empty = DVMConfig(mounts: nil, host: nil, flake: nil)

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
