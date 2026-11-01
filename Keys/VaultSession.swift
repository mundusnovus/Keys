import Foundation
import LocalAuthentication
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum VaultPhase: Equatable {
    case loading
    case setup
    case recovery
    case locked
    case mismatch
    case unlocked
}

enum VaultFilter: Hashable {
    case all
    case favorites
    case trash
    case health
    case kind(ItemKind)
    case folder(UUID)
}

@MainActor
enum KeysRuntime {
    static weak var session: VaultSession?

    static func attach(_ session: VaultSession) {
        self.session = session
    }
}

@MainActor
enum Clipboard {
    private static var secret: String?

    static func copySecret(_ value: String) {
        secret = value
        write(value)
        let copied = value
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard secret == copied else { return }
            if current() == copied { write("") }
            if secret == copied { secret = nil }
        }
    }

    static func clearSecrets() {
        if let secret, current() == secret { write("") }
        secret = nil
    }

    private static func write(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        if !value.isEmpty {
            NSPasteboard.general.setString(value, forType: .string)
        }
        #endif
    }

    private static func current() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }
}

@MainActor @Observable
final class VaultSession {
    var phase: VaultPhase = .loading
    var items: [VaultItem] = []
    var password = ""
    var message = ""
    var syncStatus = "Not synced yet."
    var recovery = ""
    var working = false
    var autofillOn = false
    private(set) var iCloudOff = false
    private var key: Data?
    private var started = false
    private var syncTail: Task<Void, Never>?
    private let cloud = CloudSync()

    var folders: [VaultItem] {
        items.filter { $0.kind == .folder && $0.deleted == nil }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    func visible(filter: VaultFilter, query: String) -> [VaultItem] {
        items.filter { item in
            switch filter {
            case .all: item.deleted == nil && item.kind != .folder
            case .favorites: item.deleted == nil && item.favorite
            case .trash: item.deleted != nil
            case .health: false
            case .kind(let kind): item.deleted == nil && item.kind == kind
            case .folder(let id): item.deleted == nil && item.folderID == id
            }
        }
        .filter { $0.matchesQuery(query) }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    func searchTitles(_ words: String) -> [String] {
        guard key != nil else { return [] }
        return visible(filter: .all, query: words).prefix(5).map(\.displayTitle)
    }

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        let rules = VaultRules.run()
        assert(rules == "ok", rules)
        #endif
        let local = VaultDisk.read()
        switch await cloud.lookupHeader() {
        case .found(let header):
            if let local {
                if local.header.salt != header.salt, !cloud.isPaused() {
                    phase = .mismatch
                    return
                }
            } else {
                var file = VaultFile.empty(header: header)
                file.headerNeedsUpload = false
                try? VaultDisk.write(file)
                message = "This iCloud account already has a Keys vault."
            }
            phase = .locked
            scheduleSync()
        case .absent:
            phase = local == nil ? .setup : .locked
            if local != nil { scheduleSync() }
        case .unavailable:
            iCloudOff = true
            phase = local == nil ? .setup : .locked
            if local == nil {
                message = "iCloud is not available. A vault created now stays on this device until iCloud is back."
            } else {
                syncStatus = "iCloud is not available. This vault stays on this device until it is."
            }
        }
        autofillOn = await IdentityPublisher.autofillEnabled()
    }

    func create(password typed: String, confirm: String) async {
        guard typed == confirm else {
            message = "Those passwords do not match."
            return
        }
        guard typed.count >= VaultCrypto.minimumPasswordLength else {
            message = "Use at least 12 characters."
            return
        }
        working = true
        defer { working = false }
        if case .found(let header) = await cloud.lookupHeader() {
            var file = VaultFile.empty(header: header)
            file.headerNeedsUpload = false
            try? VaultDisk.write(file)
            phase = .locked
            message = "This iCloud account already has a Keys vault. Unlock it with that master password."
            return
        }
        do {
            let made = try await Task.detached {
                try VaultCrypto.makeVault(password: typed)
            }.value
            try VaultDisk.write(VaultFile.empty(header: made.header))
            key = made.key
            items = []
            try? DeviceKey.save(made.key)
            recovery = Base32.groups(made.recovery)
            password = ""
            message = ""
            phase = .recovery
            scheduleSync()
        } catch {
            message = error.localizedDescription
        }
    }

    func acknowledgeRecovery() {
        recovery = ""
        phase = .unlocked
    }

    func unlock() async {
        guard let file = VaultDisk.read() else {
            message = "Create a vault first."
            return
        }
        let typed = password
        working = true
        defer { working = false }
        do {
            let opened = try await Task.detached {
                try VaultCrypto.unlock(password: typed, header: file.header)
            }.value
            try await adopt(opened, file: file)
            password = ""
            message = ""
            try? DeviceKey.save(opened)
            phase = .unlocked
            scheduleSync()
        } catch {
            message = "That password does not open this vault."
        }
    }

    func unlockBiometric() async {
        let context = LAContext()
        context.localizedReason = "Unlock Keys"
        guard let opened = DeviceKey.load(context: context), let file = VaultDisk.read() else {
            message = "Use the master password on this device once."
            return
        }
        do {
            try await adopt(opened, file: file)
            message = ""
            phase = .unlocked
            scheduleSync()
        } catch {
            message = "The vault on this device could not be opened."
        }
    }

    func lock() {
        guard phase == .unlocked || phase == .recovery else { return }
        key = nil
        items = []
        password = ""
        recovery = ""
        Clipboard.clearSecrets()
        phase = .locked
    }

    func keepLocalVault() {
        cloud.pause()
        phase = .locked
        message = "Sync is paused. This device keeps its own vault."
    }

    func useICloudVault() async {
        working = true
        defer { working = false }
        key = nil
        items = []
        do {
            try await cloud.replaceWithRemote()
            phase = .locked
            message = "Unlock the iCloud vault with its master password. The vault that was only on this device is gone."
        } catch {
            message = error.localizedDescription
        }
    }

    func save(_ item: VaultItem) {
        var stored = item
        if let existing = items.first(where: { $0.id == item.id }) {
            if existing == stored { return }
            if existing.password != stored.password, !existing.password.isEmpty {
                stored.passwordHistory = Array(([existing.password] + existing.passwordHistory).prefix(5))
            }
        }
        stored.revised = Date()
        do {
            try persist(stored)
            message = ""
            scheduleSync()
            Task { await IdentityPublisher.publish(items) }
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.deleted = Date()
        item.revised = Date()
        try? persist(item)
        scheduleSync()
        Task { await IdentityPublisher.publish(items) }
    }

    func restore(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.deleted = nil
        item.revised = Date()
        try? persist(item)
        scheduleSync()
        Task { await IdentityPublisher.publish(items) }
    }

    func emptyTrash() {
        guard let key else { return }
        try? VaultDisk.update { file in
            for index in file.records.indices {
                guard !file.records[index].needsDelete,
                      let item = try? VaultBox.open(file.records[index], key: key),
                      item.deleted != nil else { continue }
                file.records[index].needsDelete = true
            }
        }
        items.removeAll { $0.deleted != nil }
        scheduleSync()
        Task { await IdentityPublisher.publish(items) }
    }

    func toggleFavorite(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        save(item)
    }

    func importItems(_ incoming: [VaultItem]) -> String {
        var added = 0
        var skipped = 0
        for var item in incoming {
            let duplicate = items.contains { existing in
                existing.deleted == nil
                    && existing.kind == item.kind
                    && existing.title == item.title
                    && existing.username == item.username
                    && existing.uris.first == item.uris.first
            }
            if duplicate {
                skipped += 1
                continue
            }
            item.id = item.kind == .folder ? item.id : item.id
            item.revised = Date()
            do {
                try persist(item)
                added += 1
            } catch {
                skipped += 1
            }
        }
        scheduleSync()
        Task { await IdentityPublisher.publish(items) }
        return "Added \(added). Skipped \(skipped)."
    }

    func changePassword(current: String, newPassword: String, confirm: String) async -> String? {
        guard newPassword == confirm else { return "Those passwords do not match." }
        guard newPassword.count >= VaultCrypto.minimumPasswordLength else { return "Use at least 12 characters." }
        guard let key, let file = VaultDisk.read() else { return "Unlock Keys first." }
        do {
            let opened = try await Task.detached {
                try VaultCrypto.unlock(password: current, header: file.header)
            }.value
            guard opened == key else { return "That is not the current master password." }
            let recoveryWrap = file.header.recoveryWrap
            let header = try await Task.detached {
                try VaultCrypto.rewrap(key: key, password: newPassword, recoveryWrap: recoveryWrap)
            }.value
            try VaultDisk.update { stored in
                stored.header = header
                stored.headerNeedsUpload = true
            }
            scheduleSync()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func encryptedExport() -> Data? {
        guard let url = Optional(VaultDisk.fileURL),
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }

    func plaintextCSV() -> String {
        VaultTransfer.csv(items)
    }

    func syncNow() async {
        guard phase != .mismatch else { return }
        let report = await cloud.sync(key: key)
        switch report {
        case .synced(let status):
            syncStatus = status
            iCloudOff = false
            if key != nil { try? await reload() }
        case .mismatch:
            if phase == .unlocked || phase == .locked {
                phase = .mismatch
            }
        case .paused:
            syncStatus = "Sync is paused. This device is keeping its own vault."
        case .offline(let status):
            syncStatus = status
            iCloudOff = true
        }
        autofillOn = await IdentityPublisher.autofillEnabled()
    }

    func copy(_ secret: String) {
        guard !secret.isEmpty else { return }
        Clipboard.copySecret(secret)
    }

    private func adopt(_ opened: Data, file: VaultFile) async throws {
        let openedItems = try await Task.detached {
            try VaultBox.openAll(file, key: opened)
        }.value
        key = opened
        items = openedItems
        await IdentityPublisher.publish(openedItems)
    }

    private func reload() async throws {
        guard let key, let file = VaultDisk.read() else { return }
        items = try await Task.detached {
            try VaultBox.openAll(file, key: key)
        }.value
        await IdentityPublisher.publish(items)
    }

    private func persist(_ item: VaultItem) throws {
        guard let key else { throw VaultError.unavailable }
        let sealed = try VaultBox.seal(item, key: key)
        try VaultDisk.update { file in
            if let index = file.records.firstIndex(where: { $0.id == item.id }) {
                var record = sealed
                record.systemFields = file.records[index].systemFields
                file.records[index] = record
            } else {
                file.records.append(sealed)
            }
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private func scheduleSync() {
        let previous = syncTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.syncNow()
        }
        syncTail = task
    }
}
