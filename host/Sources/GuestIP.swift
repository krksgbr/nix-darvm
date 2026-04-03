import Foundation

/// A validated IPv4 address string. Constructed only via failable initializer
/// that checks `inet_pton`, so downstream code can assume the value is a
/// well-formed dotted-quad.
struct GuestIP: Equatable, CustomStringConvertible, Codable {
  let rawValue: String

  init?(_ string: String) {
    var addr = in_addr()
    guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
    self.rawValue = string
  }

  var description: String { rawValue }
}
