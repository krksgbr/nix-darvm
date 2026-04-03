import Foundation

/// Manages a DVM-owned block in /etc/exports for mirror mounts.
///
/// Scope is intentionally narrow:
/// - mirror mounts only
/// - one DVM VM at a time
/// - exact guest-IP access (not broad subnets)
/// - no permanent global exports beyond the DVM marker block
final class NFSExportManager {
  private static let beginMarker = "# BEGIN DVM NFS EXPORTS"
  private static let endMarker = "# END DVM NFS EXPORTS"
  private static let exportsPath = "/etc/exports"

  private let guestIP: GuestIP
  private let mapAllUser = "\(getuid()):\(getgid())"
  private let fileManager = FileManager.default

  init(guestIP: GuestIP) {
    self.guestIP = guestIP
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case nestedMirrorPaths(String, String)
    case commandFailed(command: String, exitCode: Int32, output: String)
    case malformedExportsBlock

    var description: String {
      switch self {
      case .nestedMirrorPaths(let parent, let child):
        return "NFS mirror mounts cannot be nested: \(parent) contains \(child)"
      case .commandFailed(let command, let exitCode, let output):
        return "Command failed (\(command), exit \(exitCode)): \(output)"
      case .malformedExportsBlock:
        return "Malformed DVM block in /etc/exports"
      }
    }
  }

  func install(for mounts: [MountConfig]) throws {
    let mirrorMounts = mounts.filter { $0.transport == .nfs && $0.isMirror }
    guard !mirrorMounts.isEmpty else { return }

    let paths = mirrorMounts.map(\.hostPath)
    try validate(paths: paths)

    DVMLog.log(
      phase: .mounting,
      "NFS exports: guest=\(guestIP.rawValue) paths=\(paths.map(\.rawValue).joined(separator: ","))"
    )

    let current = (try? String(contentsOfFile: Self.exportsPath, encoding: .utf8)) ?? ""
    let renderedBlock = renderBlock(for: paths)
    let updated = try replacingManagedBlock(in: current, with: renderedBlock)
    if DVMLog.debugMode {
      DVMLog.log(phase: .mounting, level: "debug", "NFS exports block:\n\(renderedBlock)")
    }

    let tempPath = "/tmp/dvm-exports-\(ProcessInfo.processInfo.processIdentifier)"
    try updated.write(toFile: tempPath, atomically: true, encoding: .utf8)
    defer { try? fileManager.removeItem(atPath: tempPath) }

    let check = try run("/usr/bin/sudo", ["/sbin/nfsd", "-F", tempPath, "checkexports"])
    if !check.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .mounting, "nfsd checkexports output:\n\(check.output)")
    }
    let copy = try run("/usr/bin/sudo", ["/bin/cp", tempPath, Self.exportsPath])
    if !copy.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .mounting, "exports install output:\n\(copy.output)")
    }

    let status = try run("/sbin/nfsd", ["status"], allowNonZeroExit: true)
    if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .mounting, "nfsd status output:\n\(status.output)")
    }
    let output = status.output.lowercased()
    if output.contains("not running") || output.contains("stopped") {
      DVMLog.log(phase: .mounting, "nfsd not running; starting service")
      let start = try run("/usr/bin/sudo", ["/sbin/nfsd", "start"])
      if !start.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DVMLog.log(phase: .mounting, "nfsd start output:\n\(start.output)")
      }
    } else {
      DVMLog.log(phase: .mounting, "nfsd running; sending update")
      let update = try run("/usr/bin/sudo", ["/sbin/nfsd", "update"])
      if !update.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DVMLog.log(phase: .mounting, "nfsd update output:\n\(update.output)")
      }
    }
  }

  func removeManagedExports() throws {
    let current = (try? String(contentsOfFile: Self.exportsPath, encoding: .utf8)) ?? ""
    let updated = try replacingManagedBlock(in: current, with: nil)
    if updated == current { return }
    DVMLog.log(phase: .stopped, "removing DVM-managed NFS exports")

    let tempPath = "/tmp/dvm-exports-\(ProcessInfo.processInfo.processIdentifier)"
    try updated.write(toFile: tempPath, atomically: true, encoding: .utf8)
    defer { try? fileManager.removeItem(atPath: tempPath) }

    let copy = try run("/usr/bin/sudo", ["/bin/cp", tempPath, Self.exportsPath])
    if !copy.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .stopped, "exports cleanup copy output:\n\(copy.output)")
    }

    let status = try run("/sbin/nfsd", ["status"], allowNonZeroExit: true)
    if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .stopped, "nfsd status output during cleanup:\n\(status.output)")
    }
    if status.output.lowercased().contains("running") {
      DVMLog.log(phase: .stopped, "nfsd still running; sending update after exports cleanup")
      let update = try run("/usr/bin/sudo", ["/sbin/nfsd", "update"])
      if !update.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DVMLog.log(phase: .stopped, "nfsd cleanup update output:\n\(update.output)")
      }
    }
  }

  private func renderBlock(for paths: [AbsolutePath]) -> String {
    let lines = paths.map { path in
      "\(quoteExportsPath(path.rawValue)) -mapall=\(mapAllUser) \(guestIP.rawValue)"
    }
    return ([Self.beginMarker] + lines + [Self.endMarker]).joined(separator: "\n")
  }

  private func replacingManagedBlock(in contents: String, with block: String?) throws -> String {
    let beginRange = contents.range(of: Self.beginMarker)
    let endRange = contents.range(of: Self.endMarker)

    switch (beginRange, endRange) {
    case (nil, nil):
      guard let block else { return contents }
      if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return block + "\n"
      }
      return contents + (contents.hasSuffix("\n") ? "" : "\n") + block + "\n"
    case let (.some(begin), .some(end)):
      guard begin.lowerBound < end.lowerBound else {
        throw Error.malformedExportsBlock
      }
      let afterEnd = contents.index(end.upperBound, offsetBy: 0)
      let suffix = contents[afterEnd...]
      let prefix = contents[..<begin.lowerBound]
      var rebuilt = String(prefix)
      if let block {
        rebuilt += block
        if !suffix.hasPrefix("\n") { rebuilt += "\n" }
        rebuilt += suffix
      } else {
        rebuilt += suffix
      }
      return rebuilt
    default:
      throw Error.malformedExportsBlock
    }
  }

  private func validate(paths: [AbsolutePath]) throws {
    let sorted = paths.map(\.rawValue).sorted()
    for parentIndex in 0..<sorted.count {
      for childIndex in (parentIndex + 1)..<sorted.count
      where isNested(parent: sorted[parentIndex], child: sorted[childIndex]) {
        throw Error.nestedMirrorPaths(sorted[parentIndex], sorted[childIndex])
      }
    }
  }

  private func isNested(parent: String, child: String) -> Bool {
    guard child.hasPrefix(parent) else { return false }
    if child == parent { return false }
    return child[parent.endIndex] == "/"
  }

  private func quoteExportsPath(_ path: String) -> String {
    let escaped =
      path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  @discardableResult
  private func run(_ executable: String, _ arguments: [String], allowNonZeroExit: Bool = false)
    throws
    -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output =
      (String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
      + (String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

    if !allowNonZeroExit && process.terminationStatus != 0 {
      let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
      throw Error.commandFailed(
        command: command,
        exitCode: process.terminationStatus,
        output: output.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return (process.terminationStatus, output)
  }
}
