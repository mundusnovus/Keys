import CryptoKit
import Foundation
import Security

enum VaultError: Error, LocalizedError, Equatable {
    case seal
    case password
    case file
    case weakPassword
    case encryptedImport
    case unavailable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .seal: "The vault could not be sealed."
        case .password: "That password does not open this vault."
        case .file: "The vault file could not be read."
        case .weakPassword: "Use at least 12 characters."
        case .encryptedImport: "That export is still encrypted. Export an unencrypted JSON file, then import it."
        case .unavailable: "The vault is not on this device yet."
        case .keychain(let status):
            switch status {
            case errSecMissingEntitlement:
                "Face ID could not be turned on because the keychain group is not available to this build."
            case errSecAuthFailed, errSecUserCanceled:
                "Face ID was cancelled."
            case errSecInteractionNotAllowed:
                "The device needs to be unlocked first."
            case errSecItemNotFound:
                "Turn on Face ID after unlocking with your master password once."
            default:
                "The keychain could not save the unlock key (error \(status))."
            }
        }
    }
}

struct VaultHeader: Codable, Sendable, Equatable {
    var salt: Data
    var iterations: Int
    var wrappedKey: Data
    var recoveryWrap: Data
    /// When the wrapped key last changed. Optional so vaults written by 1.x still decode.
    var revised: Date? = nil
}

enum VaultCrypto {
    /// OWASP's PBKDF2-HMAC-SHA256 floor. The check asserts this stays at least this high.
    nonisolated static let iterations = 600_000
    nonisolated static let keyLength = 32
    nonisolated static let minimumPasswordLength = 12

    nonisolated static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status != errSecSuccess {
            for index in data.indices {
                data[index] = UInt8.random(in: .min ... .max)
            }
        }
        return data
    }

    nonisolated static func stretch(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var block = Data(salt)
        var counter = UInt32(1).bigEndian
        withUnsafeBytes(of: counter) { block.append(contentsOf: $0) }
        var u = hmacSHA256(key: passwordData, message: block)
        var derived = u
        if iterations > 1 {
            for _ in 2...iterations {
                u = hmacSHA256(key: passwordData, message: u)
                derived = xor(derived, u)
            }
        }
        return SymmetricKey(data: derived.prefix(keyLength))
    }

    nonisolated static func makeVault(password: String) throws -> (header: VaultHeader, key: Data, recovery: Data) {
        guard password.count >= minimumPasswordLength else { throw VaultError.weakPassword }
        let salt = randomBytes(16)
        let stretched = stretch(password: password, salt: salt, iterations: iterations)
        let key = randomBytes(keyLength)
        let recovery = randomBytes(keyLength)
        let header = VaultHeader(
            salt: salt,
            iterations: iterations,
            wrappedKey: try seal(key, key: stretched),
            recoveryWrap: try seal(key, key: SymmetricKey(data: recovery)),
            revised: .now
        )
        return (header, key, recovery)
    }

    nonisolated static func unlock(password: String, header: VaultHeader) throws -> Data {
        let stretched = stretch(password: password, salt: header.salt, iterations: header.iterations)
        return try open(header.wrappedKey, key: stretched)
    }

    nonisolated static func unlock(recoveryKey: Data, header: VaultHeader) throws -> Data {
        try open(header.recoveryWrap, key: SymmetricKey(data: recoveryKey))
    }

    nonisolated static func rewrap(key: Data, password: String, recoveryWrap: Data) throws -> VaultHeader {
        guard password.count >= minimumPasswordLength else { throw VaultError.weakPassword }
        let salt = randomBytes(16)
        let stretched = stretch(password: password, salt: salt, iterations: iterations)
        return VaultHeader(
            salt: salt,
            iterations: iterations,
            wrappedKey: try seal(key, key: stretched),
            recoveryWrap: recoveryWrap,
            revised: .now
        )
    }

    nonisolated static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw VaultError.seal }
        return combined
    }

    nonisolated static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    nonisolated static func xor(_ left: Data, _ right: Data) -> Data {
        Data(zip(left, right).map { $0 ^ $1 })
    }
}

enum Base32 {
    nonisolated private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    nonisolated static func encode(_ data: Data) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (buffer >> (bits - 5)) & 31
                output.append(alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (buffer << (5 - bits)) & 31
            output.append(alphabet[index])
        }
        return output
    }

    nonisolated static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().filter { alphabet.contains($0) }
        guard !cleaned.isEmpty else { return nil }
        var output = Data()
        var buffer = 0
        var bits = 0
        for character in cleaned {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> (bits - 8)) & 255))
                bits -= 8
            }
        }
        return output
    }

    nonisolated static func groups(_ data: Data) -> String {
        let encoded = encode(data)
        var chunks: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 4, limitedBy: encoded.endIndex) ?? encoded.endIndex
            chunks.append(String(encoded[index..<next]))
            index = next
        }
        return chunks.joined(separator: " ")
    }
}
