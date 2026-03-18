import Foundation
import Security

/// Generates an ephemeral RSA 2048 CA certificate and private key for MITM TLS.
/// The CA is valid for the VM's lifetime only — never persisted to disk.
/// The PEM-encoded cert is installed in the guest trust store; the sidecar uses
/// the cert+key to issue per-hostname leaf certs on the fly.
enum EphemeralCA {

    struct GeneratedCA: Sendable {
        let certPEM: String
        let keyPEM: String
    }

    enum CAError: Error, CustomStringConvertible {
        case keyGenerationFailed(OSStatus)
        case certCreationFailed(String)
        case exportFailed(OSStatus)

        var description: String {
            switch self {
            case .keyGenerationFailed(let s):
                return "CA key generation failed: OSStatus \(s)"
            case .certCreationFailed(let detail):
                return "CA certificate creation failed: \(detail)"
            case .exportFailed(let s):
                return "CA key export failed: OSStatus \(s)"
            }
        }
    }

    /// Generate a self-signed RSA 2048 CA certificate valid for 1 year.
    static func generate() throws -> GeneratedCA {
        // Generate RSA 2048 key pair
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            let osStatus = (error?.takeRetainedValue() as? NSError)?.code ?? -1
            throw CAError.keyGenerationFailed(OSStatus(osStatus))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CAError.certCreationFailed("failed to extract public key")
        }

        // Build self-signed CA certificate using raw DER construction.
        // Security.framework doesn't have a high-level cert creation API,
        // so we build the ASN.1 DER manually.
        let certDER = try buildSelfSignedCACert(publicKey: publicKey, privateKey: privateKey)

        // Export private key to PKCS#1 DER
        var exportError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &exportError) as Data? else {
            let osStatus = (exportError?.takeRetainedValue() as? NSError)?.code ?? -1
            throw CAError.exportFailed(OSStatus(osStatus))
        }

        // PEM encode
        let certPEM = pemEncode(data: certDER, label: "CERTIFICATE")
        let keyPEM = pemEncode(data: keyData, label: "RSA PRIVATE KEY")

        return GeneratedCA(certPEM: certPEM, keyPEM: keyPEM)
    }

    // MARK: - DER Certificate Construction

    /// Build a minimal self-signed X.509 v3 CA certificate in DER format.
    private static func buildSelfSignedCACert(publicKey: SecKey, privateKey: SecKey) throws -> Data {
        // Extract public key DER
        var pubError: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, &pubError) as Data? else {
            throw CAError.certCreationFailed("failed to export public key")
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-5 * 60) // 5 min clock skew
        let notAfter = Calendar.current.date(byAdding: .year, value: 1, to: now)!

        // Subject/Issuer: CN=DVM Sandbox CA
        let subject = derSequence([
            derSet([
                derSequence([
                    derOID([2, 5, 4, 3]), // OID: commonName
                    derUTF8String("DVM Sandbox CA"),
                ])
            ])
        ])

        // SubjectPublicKeyInfo (RSA)
        let spki = derSequence([
            derSequence([
                derOID([1, 2, 840, 113549, 1, 1, 1]), // rsaEncryption
                derNull(),
            ]),
            derBitString(pubKeyData),
        ])

        // Serial number (random 16 bytes)
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F // ensure positive

        // Extensions: Basic Constraints (CA:TRUE), Key Usage (keyCertSign, cRLSign)
        let extensions = derExplicit(tag: 3, content: derSequence([
            // Basic Constraints: critical, CA=TRUE
            derSequence([
                derOID([2, 5, 29, 19]),
                derBoolean(true), // critical
                derOctetString(derSequence([derBoolean(true)])), // CA=TRUE
            ]),
            // Key Usage: critical, keyCertSign | cRLSign (bit 5 and 6)
            derSequence([
                derOID([2, 5, 29, 15]),
                derBoolean(true), // critical
                derOctetString(derBitStringValue(Data([0x06]))), // keyCertSign | cRLSign
            ]),
        ]))

        // TBSCertificate
        let tbs = derSequence([
            derExplicit(tag: 0, content: derInteger(2)), // version v3
            derInteger(serial),
            derSequence([derOID([1, 2, 840, 113549, 1, 1, 11]), derNull()]), // sha256WithRSAEncryption
            subject, // issuer (self-signed)
            derSequence([derUTCTime(notBefore), derUTCTime(notAfter)]), // validity
            subject, // subject
            spki,
            extensions,
        ])

        // Sign TBS with private key
        let tbsData = Data(tbs)
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsData as CFData,
            &signError
        ) as Data? else {
            throw CAError.certCreationFailed("signing failed: \(signError?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        // Full certificate
        let cert = derSequence([
            tbs,
            derSequence([derOID([1, 2, 840, 113549, 1, 1, 11]), derNull()]), // signatureAlgorithm
            derBitString(signature),
        ])

        return Data(cert)
    }

    // MARK: - PEM Encoding

    private static func pemEncode(data: Data, label: String) -> String {
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    // MARK: - ASN.1 DER Primitives

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    private static func derTLV(tag: UInt8, content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    private static func derSequence(_ items: [[UInt8]]) -> [UInt8] {
        let content = items.flatMap { $0 }
        return derTLV(tag: 0x30, content: content)
    }

    private static func derSet(_ items: [[UInt8]]) -> [UInt8] {
        let content = items.flatMap { $0 }
        return derTLV(tag: 0x31, content: content)
    }

    private static func derInteger(_ value: Int) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return derTLV(tag: 0x02, content: bytes)
    }

    private static func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return derTLV(tag: 0x02, content: b)
    }

    private static func derBoolean(_ value: Bool) -> [UInt8] {
        derTLV(tag: 0x01, content: [value ? 0xFF : 0x00])
    }

    private static func derNull() -> [UInt8] {
        [0x05, 0x00]
    }

    private static func derOctetString(_ content: [UInt8]) -> [UInt8] {
        derTLV(tag: 0x04, content: content)
    }

    private static func derBitString(_ data: Data) -> [UInt8] {
        derTLV(tag: 0x03, content: [0x00] + Array(data)) // 0 unused bits
    }

    private static func derBitStringValue(_ data: Data) -> [UInt8] {
        derTLV(tag: 0x03, content: [0x00] + Array(data))
    }

    private static func derUTF8String(_ string: String) -> [UInt8] {
        derTLV(tag: 0x0C, content: Array(string.utf8))
    }

    private static func derExplicit(tag: Int, content: [UInt8]) -> [UInt8] {
        derTLV(tag: UInt8(0xA0 | tag), content: content)
    }

    private static func derOID(_ components: [UInt]) -> [UInt8] {
        guard components.count >= 2 else { return [] }
        var encoded: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for i in 2..<components.count {
            var c = components[i]
            if c < 128 {
                encoded.append(UInt8(c))
            } else {
                var bytes: [UInt8] = []
                bytes.append(UInt8(c & 0x7F))
                c >>= 7
                while c > 0 {
                    bytes.append(UInt8(c & 0x7F) | 0x80)
                    c >>= 7
                }
                encoded.append(contentsOf: bytes.reversed())
            }
        }
        return derTLV(tag: 0x06, content: encoded)
    }

    private static func derUTCTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date) + "Z"
        return derTLV(tag: 0x17, content: Array(str.utf8))
    }
}
