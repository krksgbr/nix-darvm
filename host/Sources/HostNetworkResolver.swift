import Foundation

/// Resolves host-side IPv4 addresses for guest-reachable vmnet networks.
enum HostNetworkResolver {
  struct Resolution: CustomStringConvertible {
    let interfaceName: String
    let hostIP: GuestIP
    let netmask: GuestIP

    var description: String {
      "iface=\(interfaceName) host=\(hostIP) netmask=\(netmask)"
    }
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case noMatchingInterface(String)
    case invalidInterfaceAddress(String)

    var description: String {
      switch self {
      case .noMatchingInterface(let guestIP):
        return "Could not find a host IPv4 interface in the same subnet as guest IP \(guestIP)"

      case .invalidInterfaceAddress(let address):
        return "Resolved an invalid IPv4 address while inspecting host interfaces: \(address)"
      }
    }
  }

  static func resolve(reachableFrom guestIP: GuestIP) throws -> Resolution {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
      throw Error.noMatchingInterface(guestIP.rawValue)
    }
    defer { freeifaddrs(ifaddrPtr) }

    let guest = try IPv4(guestIP.rawValue)
    var cursor: UnsafeMutablePointer<ifaddrs>? = first

    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }

      guard let addr = current.pointee.ifa_addr,
        addr.pointee.sa_family == UInt8(AF_INET),
        let netmask = current.pointee.ifa_netmask,
        netmask.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      let candidate = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        IPv4(sockaddrIn: $0.pointee)
      }
      let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        IPv4(sockaddrIn: $0.pointee)
      }
      guard candidate.isGlobalUnicast else {
        continue
      }

      if candidate.networkAddress(mask: mask) == guest.networkAddress(mask: mask) {
        guard let hostIP = GuestIP(candidate.string) else {
          throw Error.invalidInterfaceAddress(candidate.string)
        }
        guard let netmaskIP = GuestIP(mask.string) else {
          throw Error.invalidInterfaceAddress(mask.string)
        }
        return Resolution(
          interfaceName: String(cString: current.pointee.ifa_name),
          hostIP: hostIP,
          netmask: netmaskIP
        )
      }
    }

    throw Error.noMatchingInterface(guestIP.rawValue)
  }

  private struct IPv4: Equatable {
    let rawValue: UInt32

    init(_ string: String) throws {
      var addr = in_addr()
      guard inet_pton(AF_INET, string, &addr) == 1 else {
        throw Error.noMatchingInterface(string)
      }
      rawValue = UInt32(bigEndian: addr.s_addr)
    }

    init(sockaddrIn: sockaddr_in) {
      rawValue = UInt32(bigEndian: sockaddrIn.sin_addr.s_addr)
    }

    var isGlobalUnicast: Bool {
      let firstOctet = (rawValue >> 24) & 0xff
      if firstOctet == 127 || firstOctet == 0 {
        return false
      }
      if (rawValue & 0xffff_0000) == 0xa9fe_0000 {
        return false  // 169.254.0.0/16
      }
      return true
    }

    func networkAddress(mask: IPv4) -> UInt32 {
      rawValue & mask.rawValue
    }

    var string: String {
      "\( (rawValue >> 24) & 0xff ).\( (rawValue >> 16) & 0xff ).\( (rawValue >> 8) & 0xff ).\( rawValue & 0xff )"
    }
  }
}
