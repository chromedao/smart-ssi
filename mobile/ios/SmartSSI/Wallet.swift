import CryptoKit
import Foundation
import Security

/// The user's Solana wallet for the prototype: an Ed25519 key generated on the phone and kept in the Keychain.
/// It never leaves the device; it only signs requests to the issuer API.
struct Wallet {
    private let key: Curve25519.Signing.PrivateKey

    var address: String { Base58.encode(key.publicKey.rawRepresentation) }

    func sign(_ message: String) throws -> String {
        try key.signature(for: Data(message.utf8)).base64EncodedString()
    }

    static func loadOrCreate() throws -> Wallet {
        let account = "smart-ssi.wallet"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return Wallet(key: try Curve25519.Signing.PrivateKey(rawRepresentation: data))
        }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(status)) }
        return Wallet(key: key)
    }
}

/// Bitcoin-alphabet Base58, as used for Solana addresses.
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func encode(_ data: Data) -> String {
        var digits: [Int] = [0]
        for byte in data {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        let zeros = data.prefix(while: { $0 == 0 }).count
        let body = digits.reversed().drop(while: { $0 == 0 }).map { alphabet[$0] }
        return String(repeating: "1", count: zeros) + String(body)
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
