import Foundation

/// A path relative to the guest home directory. Rejects empty strings,
/// absolute paths, and paths that start with `..`.
struct HomeRelativePath: CustomStringConvertible {
  /// Top-level home subdirectories that must not be mounted from the host.
  /// `.local` contains shared tool state (databases, logs), and `.cache`
  /// contains mutable caches such as Nix's SQLite-backed eval/fetcher state.
  /// Both must live on the guest's native APFS for reliable fsync semantics.
  static let reservedLocalPaths: Set<String> = [".local", ".cache"]

  let rawValue: String

  var description: String { rawValue }

  /// The first path component (e.g., ".local" from ".local/share/foo").
  var topLevelComponent: String {
    String(rawValue.prefix { $0 != "/" })
  }

  init(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("..") else {
      throw HomeLinkError.invalidSubpath(path)
    }
    self.rawValue = path
  }
}

/// A symlink from `~/subpath` to a VirtioFS mount point (e.g., `/var/dvm-mounts/home-0`).
struct HomeLink: CustomStringConvertible {
  let subpath: HomeRelativePath
  let target: AbsolutePath

  var description: String { "~/\(subpath) -> \(target)" }
}

enum HomeLinkError: Error, CustomStringConvertible {
  case invalidSubpath(String)
  case reservedPath(String)
  case notUnderHome(String)

  var description: String {
    switch self {
    case .invalidSubpath(let path):
      return "Invalid home-relative path: \(path)"

    case .reservedPath(let path):
      return "'\(path)' is reserved for the guest's local APFS disk "
        + "(required for reliable fsync semantics) and cannot be mounted from the host"

    case .notUnderHome(let path):
      return "'\(path)' is not inside the host home directory — "
        + "[mounts.home] dirs must be subdirectories of ~; "
        + "use [mounts.mirror] for project dirs or [mounts.system] for read-only system paths"
    }
  }
}

/// Generates a shell script that installs HomeLinks as symlinks under the
/// guest home directory. For each HomeLink it creates or updates the symlink
/// at `~/subpath`, replacing empty directories and updating existing symlinks.
func makeHomeLinkInstallScript(homeLinks: [HomeLink], guestHome: String) -> String {
  var parts: [String] = ["# HomeLink installation"]

  for link in homeLinks {
    let fullGuestPath = "\(guestHome)/\(link.subpath.rawValue)"
    let quotedGuestPath = shellQuote(fullGuestPath)
    let quotedTarget = shellQuote(link.target.rawValue)
    let parentDir = shellQuote(
      URL(fileURLWithPath: fullGuestPath).deletingLastPathComponent().path
    )

    parts.append("mkdir -p \(quotedTarget)")
    parts.append("mkdir -p \(parentDir)")
    parts.append(
      """
      if [ -L \(quotedGuestPath) ]; then ln -sfn \(quotedTarget) \(quotedGuestPath); \
      elif [ -d \(quotedGuestPath) ]; then \
        if [ -z \"$(ls -A \(quotedGuestPath) 2>/dev/null)\" ]; then \
          rmdir \(quotedGuestPath) && ln -sfn \(quotedTarget) \(quotedGuestPath); \
        else \
          backup_path=\"$(printf '%s' \(quotedGuestPath).dvm-backup-$(date +%Y%m%d-%H%M%S)-$$)\"; \
          if mv \(quotedGuestPath) \"$backup_path\"; then \
            echo \"WARN: moved existing non-empty directory \(quotedGuestPath) to $backup_path; \" \
              \"installed home link instead.\" >&2; \
            ln -sfn \(quotedTarget) \(quotedGuestPath); \
          else \
            echo \"ERROR: \(quotedGuestPath) is a non-empty directory and could not be moved aside.\" >&2; \
            echo \"Remove it manually: rm -rf \(quotedGuestPath)\" >&2; exit 1; \
          fi; fi; \
      else ln -sfn \(quotedTarget) \(quotedGuestPath); fi
      """)
  }

  return parts.joined(separator: "\n")
}
