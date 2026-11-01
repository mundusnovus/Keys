import CryptoKit
import Foundation

enum ItemKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case login, note, password, card, identity, passkey, wifi, code, folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .login: "Login"
        case .note: "Secure note"
        case .password: "Password"
        case .card: "Card"
        case .identity: "Identity"
        case .passkey: "Passkey"
        case .wifi: "Wi-Fi"
        case .code: "Code"
        case .folder: "Folder"
        }
    }

    var symbol: String {
        switch self {
        case .login: "person.crop.rectangle"
        case .note: "note.text"
        case .password: "key"
        case .card: "creditcard"
        case .identity: "person.text.rectangle"
        case .passkey: "person.badge.key"
        case .wifi: "wifi"
        case .code: "number"
        case .folder: "folder"
        }
    }

    var narrow: Bool { self == .code || self == .password }
}

struct VaultItem: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var kind: ItemKind
    var title: String
    var username: String
    var password: String
    var uris: [String]
    var totp: String
    var notes: String
    var folderID: UUID?
    var favorite: Bool
    var reprompt: Bool
    var created: Date
    var revised: Date
    var deleted: Date?
    var passwordHistory: [String]
    var cardholder: String
    var number: String
    var expiry: String
    var securityCode: String
    var firstName: String
    var lastName: String
    var email: String
    var phone: String
    var address: String
    var relyingParty: String
    var userHandle: Data
    var credentialID: Data
    var privateKey: Data
    var signCount: UInt32

    init(kind: ItemKind, now: Date = .now) {
        id = UUID()
        self.kind = kind
        title = ""
        username = ""
        password = ""
        uris = []
        totp = ""
        notes = ""
        folderID = nil
        favorite = false
        reprompt = false
        created = now
        revised = now
        deleted = nil
        passwordHistory = []
        cardholder = ""
        number = ""
        expiry = ""
        securityCode = ""
        firstName = ""
        lastName = ""
        email = ""
        phone = ""
        address = ""
        relyingParty = ""
        userHandle = Data()
        credentialID = Data()
        privateKey = Data()
        signCount = 0
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if kind == .identity {
            let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Untitled"
    }

    var primaryHost: String {
        if kind == .passkey {
            let party = relyingParty.trimmingCharacters(in: .whitespacesAndNewlines)
            if !party.isEmpty { return party }
        }
        for uri in uris {
            if let host = VaultLink.host(of: uri) { return host }
        }
        return displayTitle
    }

    /// Search covers names and notes. Passwords, codes, and keys are not searchable.
    func matchesQuery(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return true }
        let fields = [displayTitle, username, notes, primaryHost, email, cardholder, firstName, lastName]
        if fields.contains(where: { $0.lowercased().contains(needle) }) { return true }
        return uris.contains { $0.lowercased().contains(needle) }
    }

    func matches(service: String) -> Bool {
        let needle = service.lowercased()
        guard !needle.isEmpty else { return true }
        if primaryHost.lowercased().contains(needle) || needle.contains(primaryHost.lowercased()), !primaryHost.isEmpty {
            return true
        }
        if displayTitle.lowercased().contains(needle) { return true }
        return uris.contains { $0.lowercased().contains(needle) }
    }

    /// Secret fields that must never be merged silently.
    func sameSecrets(as other: VaultItem) -> Bool {
        password == other.password
            && notes == other.notes
            && totp == other.totp
            && number == other.number
            && securityCode == other.securityCode
            && privateKey == other.privateKey
            && credentialID == other.credentialID
    }
}

enum VaultLink {
    nonisolated static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else {
            return trimmed.contains(" ") ? nil : trimmed
        }
        return host
    }
}

struct SealedRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var ciphertext: Data
    var revision: Date
    var systemFields: Data?
    var needsUpload: Bool
    var needsDelete: Bool
}

struct VaultFile: Codable, Sendable, Equatable {
    var version: Int
    var header: VaultHeader
    var headerNeedsUpload: Bool
    var records: [SealedRecord]
    var headerSystemFields: Data?

    static func empty(header: VaultHeader) -> VaultFile {
        VaultFile(version: 1, header: header, headerNeedsUpload: true, records: [], headerSystemFields: nil)
    }
}

enum VaultBox {
    nonisolated static func seal(_ item: VaultItem, key: Data) throws -> SealedRecord {
        let plain = try JSONEncoder().encode(item)
        let ciphertext = try VaultCrypto.seal(plain, key: SymmetricKey(data: key))
        return SealedRecord(
            id: item.id,
            ciphertext: ciphertext,
            revision: item.revised,
            systemFields: nil,
            needsUpload: true,
            needsDelete: false
        )
    }

    nonisolated static func open(_ record: SealedRecord, key: Data) throws -> VaultItem {
        let plain = try VaultCrypto.open(record.ciphertext, key: SymmetricKey(data: key))
        return try JSONDecoder().decode(VaultItem.self, from: plain)
    }

    nonisolated static func openAll(_ file: VaultFile, key: Data) throws -> [VaultItem] {
        try file.records.filter { !$0.needsDelete }.map { try open($0, key: key) }
    }

    /// Keeps the newer secret. When both sides changed a secret, the older one comes back as its own item.
    nonisolated static func resolve(local: VaultItem, remote: VaultItem) -> (current: VaultItem, conflict: VaultItem?) {
        let newer = remote.revised >= local.revised ? remote : local
        let older = remote.revised >= local.revised ? local : remote
        guard !newer.sameSecrets(as: older) else { return (newer, nil) }
        var conflict = older
        conflict.id = UUID()
        conflict.title = "Conflict · \(older.displayTitle)"
        conflict.revised = Date()
        conflict.deleted = nil
        conflict.folderID = older.folderID
        return (newer, conflict)
    }
}

enum VaultDisk {
    nonisolated static let appGroup = "group.technology.asteria.keys"
    nonisolated static let keychainService = "technology.asteria.keys"
    nonisolated static let keychainAccount = "vault-key"
    nonisolated static let keychainAccessGroup = "technology.asteria.keys"
    nonisolated static let containerID = "iCloud.technology.asteria.keys"
    nonisolated static let zoneName = "KeysVault"

    nonisolated static var directory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Keys", isDirectory: true)
    }

    nonisolated static var fileURL: URL { directory.appendingPathComponent("vault.keys") }
    nonisolated static var syncStateURL: URL { directory.appendingPathComponent("sync-state.data") }

    nonisolated static func read() -> VaultFile? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var result: VaultFile?
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            result = try? JSONDecoder().decode(VaultFile.self, from: data)
        }
        return result
    }

    nonisolated static func write(_ file: VaultFile) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    nonisolated static func update(_ body: (inout VaultFile) throws -> Void) throws {
        guard var file = read() else { throw VaultError.file }
        try body(&file)
        try write(file)
    }
}
