import CloudKit
import Foundation
import LocalAuthentication
import Network
import Observation
import SwiftUI
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

/// A request from Siri, Shortcuts, or a deep link to compose a new item. It carries no secret: the
/// password is generated on the device and shown in the editor for review.
struct ComposeRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var kind: ItemKind = .login
    var title = ""
    var site = ""
    var username = ""
    var note = ""
    var generatePassword = true
}

/// The app-level handle App Intents use. Intents are not main-actor by default, so every access hops here.
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
    private static var clearTask: Task<Void, Never>?

    /// Copies a secret and clears it after the person's chosen delay. A delay of 0 never clears automatically.
    static func copySecret(_ value: String, clearAfter seconds: TimeInterval) {
        guard !value.isEmpty else { return }
        secret = value
        write(value)
        clearTask?.cancel()
        guard seconds > 0 else { return }
        let copied = value
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, secret == copied else { return }
            if current() == copied { write("") }
            if secret == copied { secret = nil }
        }
    }

    static func clearSecrets() {
        clearTask?.cancel()
        clearTask = nil
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

@MainActor
@Observable
final class VaultSession {
    var phase: VaultPhase = .loading
    var items: [VaultItem] = []
    var password = ""
    var message = ""
    var recovery = ""
    var working = false
    var autofillOn = false
    var iCloudOff = false
    var needsPasswordReset = false
    var recoveryMessage = ""
    var suggestBiometrics = false
    var setupBlockedForICloud = false

    // Sync, mirrored from CloudSync so SwiftUI observes one object.
    var syncPhase: SyncPhase = .idle
    var lastSync: Date?
    var syncMessage = "Not synced yet."
    var syncError: String?
    var pendingUploads = 0
    var pendingDeletes = 0
    var iCloudAccount = "Checking iCloud…"
    var syncAvailable = CloudSync.isAllowed
    var demoMode = false

    // Biometrics.
    var biometricsAvailable = DeviceKey.canAuthenticate
    var biometricsEnabled = false
    var biometricsMessage = ""

    // Navigation requests from Siri, Handoff, or a command.
    var openItemID: UUID?
    var searchRequest: String?
    var newItemRequest: ItemKind?
    var composeRequest: ComposeRequest?
    var captureRequest: String?

    let preferences: KeysPreferences

    @ObservationIgnored private var key: Data?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var syncTail: Task<Void, Never>?
    @ObservationIgnored private var autoLockTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private let cloud = CloudSync()
    @ObservationIgnored private var syncTimer: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathStatus: NWPath.Status?

    init(preferences: KeysPreferences) {
        self.preferences = preferences
    }

    // MARK: - Derived state

    var folders: [VaultItem] {
        items.filter { $0.kind == .folder && $0.deleted == nil }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    var stats: VaultStats { VaultStats(items: items) }
    var findings: [AuditFinding] { VaultAudit.findings(items) }
    var favoriteCount: Int { items.filter { $0.deleted == nil && $0.favorite }.count }
    var trashCount: Int { items.filter { $0.deleted != nil }.count }

    var liveCount: Int { items.filter { $0.deleted == nil && $0.kind != .folder }.count }

    var syncContainer: String { VaultDisk.containerID }
    var syncEnvironment: String {
        #if DEBUG
        "Development"
        #else
        "Production"
        #endif
    }
    var storageBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: VaultDisk.fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var recents: [VaultItem] {
        items.filter { $0.deleted == nil && $0.kind != .folder }
            .sorted { $0.revised > $1.revised }
            .prefix(5)
            .map { $0 }
    }

    func item(_ id: UUID?) -> VaultItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func visible(filter: VaultFilter, query: String) -> [VaultItem] {
        let healthIDs = Set(findings.map(\.itemID))
        return items.filter { item in
            switch filter {
            case .all: item.deleted == nil && item.kind != .folder
            case .favorites: item.deleted == nil && item.favorite
            case .trash: item.deleted != nil
            case .health: item.deleted == nil && healthIDs.contains(item.id)
            case .kind(let kind): item.deleted == nil && item.kind == kind
            case .folder(let id): item.deleted == nil && item.folderID == id
            }
        }
        .filter { $0.matchesQuery(query) }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    func count(for filter: VaultFilter) -> Int {
        visible(filter: filter, query: "").count
    }

    func searchTitles(_ words: String) -> [String] {
        guard key != nil else { return [] }
        return visible(filter: .all, query: words).prefix(5).map(\.displayTitle)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        let rules = VaultRules.run()
        assert(rules == "ok", rules)
        #endif
        biometricsAvailable = DeviceKey.canAuthenticate
        switch DeviceKey.state {
        case .stored:
            biometricsEnabled = preferences.biometricsEnabled
        case .missing:
            biometricsEnabled = false
            if preferences.biometricsEnabled {
                preferences.biometricsEnabled = false
                biometricsMessage = "\(FaceIDCopy.name) needs to be turned on again. Unlock with your master password, then enable it in Settings."
            }
        case .unavailable(let status):
            // A transient keychain failure must not switch biometrics off for good.
            biometricsEnabled = false
            if preferences.biometricsEnabled {
                biometricsMessage = "Keys couldn't open the \(FaceIDCopy.name) key right now (error \(status)). Unlock with your master password, then try again."
            }
        }

        #if DEBUG
        if DemoVault.isRequested, let demo = (try? DemoVault.load()) ?? nil {
            key = demo.key
            items = demo.items
            phase = .unlocked
            demoMode = true
            syncAvailable = false
            syncPhase = .paused
            syncMessage = "Demo vault. iCloud is off for this run."
            syncError = nil
            pendingUploads = 0
            pendingDeletes = 0
            iCloudAccount = "Demo mode"
            autofillOn = false
            if DemoVault.openFirst { openItemID = demo.items.first?.id }
            if ProcessInfo.processInfo.arguments.contains("-biometric-flow") {
                await runBiometricFlow(demo.key)
                return
            }
            return
        }
        #endif

        observeAccountChanges()
        startSyncServices()
        let local = VaultDisk.read()
        setupBlockedForICloud = false
        switch await cloud.lookupHeader() {
        case .found(let header):
            if let local {
                if !local.header.isSameVault(as: header), !cloud.isPaused() {
                    phase = .mismatch
                    reflectCloud()
                    return
                }
            } else {
                var file = VaultFile.empty(header: header)
                file.headerNeedsUpload = false
                try? VaultDisk.write(file)
                // A new device (or a vault erased without its state) must fetch every record, not only
                // the changes after a token this device never should have kept.
                cloud.resetToken()
                message = "This iCloud account already has a Keys vault. Unlock it with the master password from your other device."
            }
            phase = .locked
            scheduleSync()
        case .absent:
            phase = local == nil ? .setup : .locked
            if local != nil { scheduleSync() }
        case .unavailable:
            iCloudOff = true
            if local == nil {
                phase = .setup
                if cloud.isEnabled {
                    // Never invite a second vault while an iCloud vault might exist but cannot be read.
                    // The person can retry, or explicitly choose a device-only vault.
                    setupBlockedForICloud = true
                    message = cloud.lastLookupError
                        ?? "iCloud is not available. Check the connection and try again, or create a vault on this device only."
                } else {
                    setupBlockedForICloud = false
                    message = "iCloud is off for this build. A vault created now stays on this device."
                }
            } else {
                phase = .locked
                syncMessage = cloud.lastLookupError ?? "iCloud is not available. This vault stays on this device until it is."
            }
        }
        autofillOn = await IdentityPublisher.autofillEnabled()
        iCloudAccount = await cloud.accountExplanation()
        reflectCloud()
        KeysIntelligence.prewarm()
    }

    func noteActive() async {
        autoLockTask?.cancel()
        autoLockTask = nil
        if let backgroundedAt {
            let elapsed = Date.now.timeIntervalSince(backgroundedAt)
            if preferences.autoLock != .immediately, elapsed >= Double(preferences.autoLock.rawValue) {
                lock()
            }
        }
        backgroundedAt = nil
        guard phase == .unlocked || phase == .locked else { return }
        await syncNow()
    }

    func noteBackground() {
        backgroundedAt = .now
        autoLockTask?.cancel()
        Clipboard.clearSecrets()
        guard phase == .unlocked else { return }
        let delay = preferences.autoLock
        if delay == .immediately {
            lock()
            return
        }
        autoLockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay.rawValue))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lock() }
        }
    }

    // MARK: - Setup and unlock

    /// Retries the iCloud header lookup without leaving the setup screen. A missing schema or a
    /// different CloudKit environment is reported here instead of silently starting a second vault.
    func retryICloudForSetup() async {
        guard phase == .setup else { return }
        setupBlockedForICloud = true
        message = "Checking iCloud…"
        switch await cloud.lookupHeader() {
        case .found(let header):
            var file = VaultFile.empty(header: header)
            file.headerNeedsUpload = false
            try? VaultDisk.write(file)
            cloud.resetToken()
            setupBlockedForICloud = false
            phase = .locked
            message = "This iCloud account already has a Keys vault. Unlock it with the master password from your other device."
            reflectCloud()
        case .absent:
            setupBlockedForICloud = false
            iCloudOff = false
            message = ""
        case .unavailable:
            setupBlockedForICloud = true
            message = cloud.lastLookupError
                ?? "iCloud is still not available. Check the connection and try again."
        }
    }

    /// The explicit "not now" choice. A vault created here stays local; it will not be merged with an
    /// iCloud vault made on another device without the mismatch screen.
    func allowDeviceOnlySetup() {
        setupBlockedForICloud = false
        iCloudOff = true
        message = "This vault will stay on this device until you sign in to iCloud."
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
            DeviceKey.delete()
            preferences.biometricsEnabled = false
            biometricsEnabled = false
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
        suggestBiometrics = biometricsAvailable && !biometricsEnabled
        scheduleSync()
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
            phase = .unlocked
            keepBiometricKey(opened)
            scheduleSync()
        } catch {
            message = "That password does not open this vault."
        }
    }

    func unlockBiometric() async {
        guard preferences.biometricsEnabled else {
            message = "Turn on \(FaceIDCopy.name) in Settings after unlocking with your master password once."
            return
        }
        guard DeviceKey.exists else {
            message = "The \(FaceIDCopy.name) key is no longer on this device. Unlock with your master password, then turn it on again in Settings."
            return
        }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Master Password"
        guard let file = VaultDisk.read() else {
            message = "The vault file is missing."
            return
        }
        do {
            let opened = try DeviceKey.load(context: context)
            try await adopt(opened, file: file)
            message = ""
            biometricsEnabled = true
            phase = .unlocked
            scheduleSync()
        } catch {
            let description = (error as? VaultError)?.errorDescription ?? error.localizedDescription
            message = description
            if let vaultError = error as? VaultError,
               case .keychain(let status) = vaultError, status == errSecItemNotFound {
                // The item is definitively gone. Clear both states; the person can turn it on again.
                preferences.biometricsEnabled = false
                biometricsEnabled = false
            }
        }
    }

    /// Offered after a successful password unlock. Saves the vault key behind Face ID / Touch ID.
    @discardableResult
    func enableBiometrics() -> Bool {
        guard let key else {
            biometricsMessage = "Unlock with your master password first."
            return false
        }
        guard DeviceKey.canAuthenticate else {
            biometricsMessage = "Set a device passcode or \(FaceIDCopy.name) in Settings first."
            return false
        }
        do {
            try DeviceKey.save(key)
            guard DeviceKey.exists else { throw VaultError.keychain(errSecItemNotFound) }
            preferences.biometricsEnabled = true
            biometricsEnabled = true
            biometricsMessage = ""
            return true
        } catch {
            preferences.biometricsEnabled = false
            biometricsEnabled = false
            biometricsMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func disableBiometrics() {
        DeviceKey.delete()
        preferences.biometricsEnabled = false
        biometricsEnabled = false
        biometricsMessage = "\(FaceIDCopy.name) is off. The master password is still required."
    }

    func unlockRecovery(_ code: String) async {
        guard let file = VaultDisk.read() else {
            recoveryMessage = "Create a vault first."
            return
        }
        guard let data = Base32.decode(code), !data.isEmpty else {
            recoveryMessage = "That is not a recovery key."
            return
        }
        working = true
        defer { working = false }
        do {
            let opened = try await Task.detached {
                try VaultCrypto.unlock(recoveryKey: data, header: file.header)
            }.value
            try await adopt(opened, file: file)
            phase = .unlocked
            needsPasswordReset = true
            recoveryMessage = ""
            message = "Recovery key accepted. Set a new master password now."
            scheduleSync()
        } catch {
            recoveryMessage = "That recovery key does not open this vault."
        }
    }

    func setNewPassword(_ updated: String, confirm: String) async -> String? {
        guard updated == confirm else { return "Those passwords do not match." }
        guard updated.count >= VaultCrypto.minimumPasswordLength else { return "Use at least 12 characters." }
        guard let key, let file = VaultDisk.read() else { return "Unlock Keys first." }
        do {
            let header = try await Task.detached {
                try VaultCrypto.rewrap(key: key, password: updated,
                                       recoveryWrap: file.header.recoveryWrap,
                                       vaultID: file.header.vaultID)
            }.value
            try VaultDisk.update { stored in
                stored.header = header
                stored.headerNeedsUpload = true
            }
            needsPasswordReset = false
            message = "Master password changed."
            scheduleSync()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func keepLocalVault() {
        cloud.pause()
        phase = .locked
        message = "Sync is paused. This device keeps its own vault."
        reflectCloud()
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
            reflectCloud()
        } catch {
            message = CloudSync.friendly(error)
        }
    }

    func lock() {
        guard phase == .unlocked || phase == .recovery || needsPasswordReset else { return }
        key = nil
        items = []
        password = ""
        recovery = ""
        needsPasswordReset = false
        Clipboard.clearSecrets()
        phase = .locked
        message = ""
        Task { await SpotlightIndex.removeAll() }
    }

    // MARK: - Sync

    func syncNow() async {
        guard phase != .mismatch else { return }
        guard !demoMode else {
            syncPhase = .paused
            syncMessage = "Demo vault. iCloud is off for this run."
            syncError = nil
            return
        }
        let report = await cloud.sync(key: key)
        reflectCloud()
        switch report {
        case .synced(let status):
            syncMessage = status
            syncError = nil
            iCloudOff = false
            if key != nil { try? await reload() }
        case .mismatch:
            if phase == .unlocked || phase == .locked { phase = .mismatch }
            syncError = "iCloud has a different Keys vault than this device."
        case .paused:
            syncMessage = "Sync is paused. This device is keeping its own vault."
        case .offline(let status):
            syncError = status
            // The detailed error is shown once, in red. Repeating it as the status line made the
            // sync card say the same sentence twice.
            syncMessage = "Keys couldn't finish syncing."
            iCloudOff = true
        case .busy:
            break
        }
        autofillOn = await IdentityPublisher.autofillEnabled()
        iCloudAccount = await cloud.accountExplanation()
    }

    private func reflectCloud() {
        syncPhase = cloud.phase
        lastSync = cloud.lastSync
        pendingUploads = cloud.pendingUploads
        pendingDeletes = cloud.pendingDeletes
        syncAvailable = cloud.isEnabled
        if cloud.lastMessage != "Not synced yet." { syncMessage = cloud.lastMessage }
        if let error = cloud.lastError { syncError = error }
    }

    func scheduleSync() {
        let previous = syncTail
        syncTail = Task { [weak self] in
            await previous?.value
            await self?.syncNow()
        }
    }

    /// Clears the CloudKit change token and downloads every record again. Safe to run at any time; it
    /// never deletes the local vault.
    func syncEverythingNow() async {
        guard cloud.isEnabled else {
            syncError = "iCloud is off for this build."
            return
        }
        cloud.resetToken()
        await syncNow()
        if syncError == nil {
            syncMessage = "Everything was checked against iCloud."
        }
    }

    func resumeSync() {
        cloud.resume()
        scheduleSync()
    }

    func refreshAccount() async {
        iCloudAccount = await cloud.accountExplanation()
        syncAvailable = cloud.isEnabled
    }

    func pauseSync() {
        cloud.pause()
        reflectCloud()
    }

    /// Sync while the app is open, and again when the network comes back. Saves already schedule a sync;
    /// this closes the two gaps that made a password on one device seem missing on the other: a device
    /// sitting open, and a device that was offline when the other one saved.
    private func startSyncServices() {
        guard syncTimer == nil else { return }
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .unlocked || self.phase == .locked else { continue }
                if self.pathMonitor?.currentPath.status == .satisfied {
                    await self.syncNow()
                }
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let session = self else { return }
            Task { @MainActor in
                session.notePath(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "technology.asteria.keys.network", qos: .utility))
        pathMonitor = monitor
    }

    /// A network change is not an instruction to sync immediately; it only schedules a sync when the
    /// connection returns, so a flapping network cannot spin the vault.
    private func notePath(_ path: NWPath) {
        let wasOffline = lastPathStatus != .satisfied
        lastPathStatus = path.status
        if path.status == .satisfied, wasOffline {
            scheduleSync()
        }
    }

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.iCloudAccount = await self.cloud.accountExplanation()
                await self.syncNow()
            }
        }
    }

    // MARK: - Items

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
            Task { await refreshIndexes() }
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
        Task { await refreshIndexes() }
    }

    func restore(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.deleted = nil
        item.revised = Date()
        try? persist(item)
        scheduleSync()
        Task { await refreshIndexes() }
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
        Task { await refreshIndexes() }
    }

    func toggleFavorite(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        save(item)
    }

    func duplicate(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.id = UUID()
        item.title = item.displayTitle + " copy"
        item.created = .now
        item.revised = .now
        item.favorite = false
        item.passwordHistory = []
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
            item.revised = Date()
            do {
                try persist(item)
                added += 1
            } catch {
                skipped += 1
            }
        }
        scheduleSync()
        Task { await refreshIndexes() }
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
            return await setNewPassword(newPassword, confirm: confirm)
        } catch {
            return "That is not the current master password."
        }
    }

    func copy(_ secret: String) {
        guard !secret.isEmpty else { return }
        Clipboard.copySecret(secret, clearAfter: TimeInterval(preferences.clipboardClear.rawValue))
    }

    func encryptedExport() -> Data? {
        try? Data(contentsOf: VaultDisk.fileURL)
    }

    func plaintextCSV() -> String {
        VaultTransfer.csv(items)
    }

    /// Local only: the iCloud copy stays, and comes back on the next signed-in launch. The copy says so.
    func eraseLocalVault() {
        try? FileManager.default.removeItem(at: VaultDisk.fileURL)
        try? FileManager.default.removeItem(at: VaultDisk.syncStateURL)
        DeviceKey.delete()
        preferences.biometricsEnabled = false
        biometricsEnabled = false
        key = nil
        items = []
        recovery = ""
        password = ""
        phase = .setup
        message = "This device's vault was erased. The iCloud copy will come back when you sign in again."
    }

    // MARK: - Private

    #if DEBUG
    /// Exercises the exact production path: save the key behind the keychain policy, lock, then unlock
    /// with biometrics. The result is written beside the vault for a simulator run to prove.
    private func runBiometricFlow(_ vaultKey: Data) async {
        var lines: [String] = []
        do {
            try DeviceKey.save(vaultKey)
            preferences.biometricsEnabled = true
            biometricsEnabled = true
            lock()
            lines.append("locked=\(phase == .locked)")
            await unlockBiometric()
            lines.append("phase=\(phase)")
            lines.append("items=\(items.count)")
            lines.append("message=\(message)")
        } catch {
            lines.append("error=\(error.localizedDescription)")
            lines.append("state=\(DeviceKey.state)")
        }
        DeviceKey.delete()
        preferences.biometricsEnabled = false
        biometricsEnabled = false
        key = nil
        items = []
        let url = VaultDisk.directory.appendingPathComponent("biometric-flow.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    private func adopt(_ opened: Data, file: VaultFile) async throws {
        let openedItems = try await Task.detached {
            try VaultBox.openAll(file, key: opened)
        }.value
        key = opened
        items = openedItems
        await refreshIndexes()
    }

    private func reload() async throws {
        guard let key, let file = VaultDisk.read() else { return }
        items = try await Task.detached {
            try VaultBox.openAll(file, key: key)
        }.value
        await refreshIndexes()
    }

    private func keepBiometricKey(_ opened: Data) {
        guard preferences.biometricsEnabled else { return }
        // The vault key never changes when the master password changes, so a stored key is already correct.
        // Re-saving on every password unlock caused a delete/add race and could leave biometrics broken.
        if DeviceKey.exists {
            biometricsEnabled = true
            return
        }
        do {
            try DeviceKey.save(opened)
            biometricsEnabled = true
        } catch {
            preferences.biometricsEnabled = false
            biometricsEnabled = false
            biometricsMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
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

    private func refreshIndexes() async {
        await IdentityPublisher.publish(items)
        await SpotlightIndex.reindex(items, allowed: preferences.shareWithSiri)
    }
}
