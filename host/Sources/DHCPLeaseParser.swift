import Foundation

/// Parses macOS DHCP leases to find a VM's IP address by MAC.
/// Adapted from Lume's DHCPLeaseParser.swift (MIT).
enum DHCPLeaseParser {
    private static let leasePath = "/var/db/dhcpd_leases"

    static func getIPAddress(forMAC macAddress: String) -> GuestIP? {
        let normalized = normalize(mac: macAddress)

        // Try vmnet DHCP leases first (NAT mode)
        if let contents = try? String(contentsOfFile: leasePath, encoding: .utf8) {
            let leases = parseDHCPLeases(contents)
            if let ip = leases.first(where: { $0.mac == normalized })?.ip,
               let guest = GuestIP(ip) {
                return guest
            }
        }

        // Fall back to ARP table (bridged mode)
        return getIPFromARP(forMAC: normalized)
    }

    private struct Lease {
        let mac: String
        let ip: String
    }

    private static func parseDHCPLeases(_ contents: String) -> [Lease] {
        var leases: [Lease] = []
        var current: [String: String] = [:]
        var inBlock = false

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "{" {
                inBlock = true
                current = [:]
            } else if trimmed == "}" {
                if let hwAddress = current["hw_address"],
                   let ip = current["ip_address"] {
                    let parts = hwAddress.split(separator: ",")
                    if parts.count >= 2 {
                        let mac = normalize(mac: String(parts[1]).trimmingCharacters(in: .whitespaces))
                        leases.append(Lease(mac: mac, ip: ip))
                    }
                }
                inBlock = false
            } else if inBlock {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    current[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                        String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return leases
    }

    private static func getIPFromARP(forMAC macAddress: String) -> GuestIP? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }

        let lowered = macAddress.lowercased()
        for line in output.components(separatedBy: "\n") {
            if line.lowercased().contains(lowered),
               let open = line.firstIndex(of: "("),
               let close = line.firstIndex(of: ")") {
                return GuestIP(String(line[line.index(after: open)..<close]))
            }
        }
        return nil
    }

    private static func normalize(mac: String) -> String {
        mac.split(separator: ":").map { component in
            let hex = String(component)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined(separator: ":").lowercased()
    }
}
