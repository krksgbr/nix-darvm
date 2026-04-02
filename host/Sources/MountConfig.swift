import Foundation

/// Access mode for a VirtioFS mount.
enum AccessMode {
    case readOnly
    case readWrite
}

/// Runtime transport for a guest-visible mount.
enum MountTransport: String, Codable {
    case virtiofs
    case nfs
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

/// Configuration for a host↔guest mount.
/// Mirrors use NFS in the current spike; everything else stays on VirtioFS.
enum MountConfig {
    case exact(
        tag: MountTag,
        hostPath: AbsolutePath,
        guestPath: AbsolutePath,
        access: AccessMode,
        transport: MountTransport
    )

    var tag: MountTag {
        switch self {
        case .exact(let tag, _, _, _, _):
            tag
        }
    }

    var hostPath: AbsolutePath {
        switch self {
        case .exact(_, let hostPath, _, _, _):
            hostPath
        }
    }

    var guestPath: AbsolutePath {
        switch self {
        case .exact(_, _, let guestPath, _, _):
            guestPath
        }
    }

    var access: AccessMode {
        switch self {
        case .exact(_, _, _, let access, _):
            access
        }
    }

    var transport: MountTransport {
        switch self {
        case .exact(_, _, _, _, let transport):
            transport
        }
    }

    var isMirror: Bool {
        tag.rawValue.hasPrefix("mirror-")
    }
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
