import Foundation

/// A path relative to the guest home directory. Rejects empty strings,
/// absolute paths, and paths that start with `..`.
struct HomeRelativePath: CustomStringConvertible {
  /// Top-level home subdirectories that are backed by the guest's local APFS
  /// disk (not VirtioFS). These cannot be user-mounted because VirtioFS does
  /// not provide the fsync semantics that databases and other stateful
  /// applications require.
  static let reservedLocalPaths: Set<String> = [".local"]

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

/// A symlink from `~/subpath` to an absolute target path. The target may be
/// a VirtioFS mount point (e.g., `/var/dvm-mounts/home-0`) or a local APFS
/// directory (e.g., `/var/dvm-local/.local`).
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

/// The guest-local directory root for APFS-backed home subdirectories.
let dvmLocalDir = "/var/dvm-local"

/// Returns the built-in HomeLinks for directories that must live on the
/// guest's local APFS disk rather than VirtioFS.
func builtInLocalHomeLinks() throws -> [HomeLink] {
  [
    HomeLink(
      subpath: try HomeRelativePath(".local"),
      target: try AbsolutePath("\(dvmLocalDir)/.local")
    )
  ]
}

/// Generates a shell script that installs HomeLinks as symlinks under the
/// guest home directory.
///
/// The script:
/// 1. Creates local APFS target directories under `/var/dvm-local/`
/// 2. For each HomeLink, creates or updates the symlink at `~/subpath`
/// 3. Handles migration: existing symlinks are updated, empty directories
///    are replaced, non-empty directories trigger a warning
func makeHomeLinkInstallScript(homeLinks: [HomeLink], guestHome: String) -> String {
  var parts: [String] = [
    "# HomeLink installation",
    "mkdir -p \(shellQuote(dvmLocalDir))",
    "chown 501:20 \(shellQuote(dvmLocalDir))"
  ]

  for link in homeLinks {
    let fullGuestPath = "\(guestHome)/\(link.subpath.rawValue)"
    let quotedGuestPath = shellQuote(fullGuestPath)
    let quotedTarget = shellQuote(link.target.rawValue)
    let parentDir = shellQuote(
      URL(fileURLWithPath: fullGuestPath).deletingLastPathComponent().path
    )

    parts.append("mkdir -p \(quotedTarget)")
    // Only chown APFS-backed local dirs; VirtioFS mount points are managed by the daemon.
    if link.target.rawValue.hasPrefix(dvmLocalDir + "/") {
      parts.append("chown 501:20 \(quotedTarget)")
    }
    parts.append("mkdir -p \(parentDir)")
    parts.append(
      """
      if [ -L \(quotedGuestPath) ]; then ln -sfn \(quotedTarget) \(quotedGuestPath); \
      elif [ -d \(quotedGuestPath) ]; then \
        if [ -z \"$(ls -A \(quotedGuestPath) 2>/dev/null)\" ]; then \
          rmdir \(quotedGuestPath) && ln -sfn \(quotedTarget) \(quotedGuestPath); \
        else echo \"ERROR: \(quotedGuestPath) is a non-empty directory; cannot install home link.\" >&2; \
          echo \"Remove it manually: rm -rf \(quotedGuestPath)\" >&2; exit 1; fi; \
      else ln -sfn \(quotedTarget) \(quotedGuestPath); fi
      """)
  }

  return parts.joined(separator: "\n")
}
