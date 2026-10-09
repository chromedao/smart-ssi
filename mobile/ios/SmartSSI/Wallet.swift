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

    private static let account = "smart-ssi.wallet"

    /// The key lives in the iCloud Keychain: end-to-end encrypted, synced to the user's other Apple devices and
    /// restored on a new iPhone signed in to the same Apple account. Keys from earlier builds, kept on this
    /// device only, move there on first launch. If the key is ever lost, proving GitHub again moves the badge
    /// to the new key (the issuer allows one badge per GitHub account). See docs/KEYS.md.
    static func loadOrCreate() throws -> Wallet {
        let find: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(find as CFDictionary, &item) == errSecSuccess,
           let attributes = item as? [String: Any], let data = attributes[kSecValueData as String] as? Data {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            if (attributes[kSecAttrSynchronizable as String] as? Bool) != true { try? backUp(key) }
            return Wallet(key: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return Wallet(key: key)
    }

    private static func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            // Synced items cannot be "this device only"; the iCloud Keychain encrypts them end to end.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(status)) }
    }

    /// Moves a device-only key from an earlier build into the iCloud Keychain, keeping the same key.
    private static func backUp(_ key: Curve25519.Signing.PrivateKey) throws {
        try save(key)
        let local: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(local as CFDictionary)
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
