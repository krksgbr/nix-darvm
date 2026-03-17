import Foundation

/// Access mode for a VirtioFS mount.
enum AccessMode {
    case readOnly
    case readWrite
}

/// An absolute filesystem path. Rejects empty and relative paths.
struct AbsolutePath: CustomStringConvertible {
    let rawValue: String

    init(_ path: String) throws {
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw MountConfigError.relativePath(path)
        }
        self.rawValue = path
    }

    /// Internal init for values already known to be absolute.
    private init(trusted: String) {
        self.rawValue = trusted
    }

    var description: String { rawValue }

    /// Parent directory.
    var deletingLastComponent: AbsolutePath {
        AbsolutePath(trusted:
            URL(fileURLWithPath: rawValue).deletingLastPathComponent().path
        )
    }
}

/// A VirtioFS device tag. Must be non-empty and not collide with the macOS
/// automount tag.
struct MountTag: CustomStringConvertible {
    static let macOSAutomount = "com.apple.virtio-fs.automount"

    let rawValue: String

    init(_ tag: String) throws {
        guard !tag.isEmpty, tag != Self.macOSAutomount else {
            throw MountConfigError.invalidTag(tag)
        }
        self.rawValue = tag
    }

    var description: String { rawValue }
}

/// Configuration for a VirtioFS mount between host and guest.
/// Each mount gets its own VZSingleDirectoryShare device, mounted directly at
/// guestPath via mount_virtiofs. This ensures `pwd` shows the real host path
/// (symlink-based approaches break because macOS resolves symlinks).
enum MountConfig {
    case exact(tag: MountTag, hostPath: AbsolutePath, guestPath: AbsolutePath, access: AccessMode)
}

enum MountConfigError: Error, CustomStringConvertible {
    case relativePath(String)
    case invalidTag(String)

    var description: String {
        switch self {
        case .relativePath(let p): return "Path must be absolute: \(p)"
        case .invalidTag(let t): return "Invalid mount tag: \(t)"
        }
    }
}
