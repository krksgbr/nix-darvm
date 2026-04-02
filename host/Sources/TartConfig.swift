import Foundation
import Virtualization

/// Parses Tart's config.json format to extract VM configuration.
///
/// Tart stores hardwareModel and ecid as base64-encoded strings
/// at the top level of the JSON (same container as cpuCount, etc.).
struct TartConfig {
    let cpuCount: Int
    let memorySize: UInt64
    let macAddress: VZMACAddress
    let hardwareModel: VZMacHardwareModel
    let machineIdentifier: VZMacMachineIdentifier

    /// Raw Decodable DTO matching the Tart config.json schema.
    private struct DTO: Decodable {
        let cpuCount: Int
        let memorySize: UInt64
        let macAddress: String
        let hardwareModel: String
        let ecid: String
    }

    init(fromURL url: URL) throws {
        let data = try Data(contentsOf: url)
        let dto = try JSONDecoder().decode(DTO.self, from: data)

        guard dto.cpuCount > 0 else {
            throw ConfigError.invalidField("cpuCount")
        }
        cpuCount = dto.cpuCount

        guard dto.memorySize > 0 else {
            throw ConfigError.invalidField("memorySize")
        }
        memorySize = dto.memorySize

        guard let mac = VZMACAddress(string: dto.macAddress) else {
            throw ConfigError.invalidField("macAddress")
        }
        macAddress = mac

        guard let hwModelData = Data(base64Encoded: dto.hardwareModel),
              let hwModel = VZMacHardwareModel(dataRepresentation: hwModelData) else {
            throw ConfigError.invalidField("hardwareModel")
        }
        hardwareModel = hwModel

        guard let ecidData = Data(base64Encoded: dto.ecid),
              let ecid = VZMacMachineIdentifier(dataRepresentation: ecidData) else {
            throw ConfigError.invalidField("ecid")
        }
        machineIdentifier = ecid
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case invalidField(String)
    case unknownKey(key: String, section: String, known: [String])
    case missingKey(key: String, section: String)

    var description: String {
        switch self {
        case .invalidField(let name):
            return "Invalid or missing field in config.json: \(name)"
        case .unknownKey(let key, let section, let known):
            return "Unknown key '\(key)' in \(section) of ~/.config/dvm/config.toml (valid keys: \(known.joined(separator: ", ")))"
        case .missingKey(let key, let section):
            return "Missing required key '\(key)' in \(section) of ~/.config/dvm/config.toml"
        }
    }
}
