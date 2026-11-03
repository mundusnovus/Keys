import Foundation
import Testing
@testable import KeysKit

/// Pure rules that do not need a vault, a model, iCloud, or a person. These are the checks the app's
/// DEBUG launch assertion already runs; here they fail a test run instead of trapping a debug launch.
@Suite("KeysKit rules")
struct KeysKitRulesTests {
    @Test("Crypto, TOTP, generator, import, conflict, and passkey rules")
    func vaultRules() {
        #expect(VaultRules.run() == "ok")
    }

    @Test("Base32 survives a round trip")
    func base32RoundTrip() {
        let data = Data((0..<32).map { UInt8($0 * 7) })
        let encoded = Base32.encode(data)
        #expect(Base32.decode(encoded) == data)
    }

    @Test("Rewrapping keeps the same vault key")
    func rewrap() throws {
        let original = try VaultCrypto.makeVault(password: "correct horse battery")
        let header = try VaultCrypto.rewrap(key: original.key, password: "a different long password",
                                            recoveryWrap: original.header.recoveryWrap,
                                            vaultID: original.header.vaultID)
        #expect(try VaultCrypto.unlock(password: "a different long password", header: header) == original.key)
        #expect(try VaultCrypto.unlock(recoveryKey: original.recovery, header: header) == original.key)
        #expect(header.isSameVault(as: original.header))
    }

    @Test("A 1.x vault stays the same vault after a password change")
    func legacyVaultIdentity() {
        let sharedRecovery = Data("recovery-wrap".utf8)
        let before = VaultHeader(salt: Data([1, 2, 3]), iterations: 1,
                                 wrappedKey: Data([4]), recoveryWrap: sharedRecovery)
        let after = VaultHeader(salt: Data([9, 8, 7]), iterations: 1,
                                wrappedKey: Data([5]), recoveryWrap: sharedRecovery)
        #expect(before.isSameVault(as: after))
        #expect(!before.isSameVault(as: VaultHeader(salt: Data([1]), iterations: 1,
                                                   wrappedKey: Data([4]), recoveryWrap: Data("other".utf8))))
    }

    @Test("A conflict keeps the older secret as its own item")
    func conflictKeepsBoth() {
        var local = VaultItem(kind: .login)
        local.title = "Bank"
        local.password = "one"
        local.revised = Date(timeIntervalSince1970: 10)
        var remote = local
        remote.password = "two"
        remote.revised = Date(timeIntervalSince1970: 20)
        let resolved = VaultBox.resolve(local: local, remote: remote)
        #expect(resolved.current.password == "two")
        #expect(resolved.conflict?.password == "one")
        #expect(resolved.conflict?.title.contains("Conflict") == true)
    }

    @Test("Sealing an item hides its fields")
    func sealedCiphertext() throws {
        var item = VaultItem(kind: .login)
        item.title = "Mail"
        item.password = "s3cret"
        let key = Data(repeating: 7, count: 32)
        let sealed = try VaultBox.seal(item, key: key)
        #expect(!sealed.ciphertext.contains(Data("s3cret".utf8)))
        #expect(try VaultBox.open(sealed, key: key).password == "s3cret")
    }
}
