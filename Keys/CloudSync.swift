import CloudKit
import Foundation
import Observation

enum HeaderLookup: Sendable, Equatable {
    case found(VaultHeader)
    case absent
    case unavailable
}

enum SyncReport: Sendable {
    case synced(String)
    case mismatch
    case paused
    case offline(String)
    case busy
}

enum SyncPhase: Equatable, Sendable {
    case idle
    case syncing
    case synced
    case paused
    case unavailable
    case failed

    var label: String {
        switch self {
        case .idle: "Not synced yet"
        case .syncing: "Syncing…"
        case .synced: "Synced"
        case .paused: "Sync paused"
        case .unavailable: "iCloud unavailable"
        case .failed: "Sync needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .synced: "checkmark.icloud"
        case .paused: "pause.circle"
        case .unavailable: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }
}

private enum SyncProblem: Error {
    case mismatch
}

private enum SyncFailure: LocalizedError {
    case partial([String])
    case noAccount

    var errorDescription: String? {
        switch self {
        case .partial(let messages):
            messages.first ?? "Some items could not be synced."
        case .noAccount:
            "Sign in to iCloud in Settings to keep Keys on all your devices."
        }
    }
}

/// iCloud private database. Records hold ciphertext. The master password is never uploaded.
///
/// 2.0 rules:
///   * The Mac app is sandboxed and needs `com.apple.security.network.client`; without it every CloudKit call
///     failed on the Mac, which is why a password made on the iPhone never reached it.
///   * A per-record failure is never reported as success. Unsynced records stay marked and retry.
///   * A change-token expiry resets the token and fetches everything again.
///   * The header carries a revision date so a password change on one device wins over an older wrap.
@MainActor
@Observable
final class CloudSync {
    private(set) var phase: SyncPhase = .idle
    private(set) var lastSync: Date?
    private(set) var lastMessage = "Not synced yet."
    private(set) var lastError: String?
    private(set) var lastLookupError: String?
    private(set) var pendingUploads = 0
    private(set) var pendingDeletes = 0

    /// A build without the iCloud entitlement must never construct a `CKContainer`: CloudKit traps on a
    /// background queue and no `do/catch` can stop it. `ASTERIA_CLOUDKIT=NO` keeps unsigned builds alive.
    private let container: CKContainer?
    private var database: CKDatabase? { container?.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: VaultDisk.zoneName, ownerName: CKCurrentUserDefaultName)
    private let headerName = "header"
    private var inFlight = false
    private var zoneReady = false

    init() {
        container = CloudSync.isAllowed ? CKContainer(identifier: VaultDisk.containerID) : nil
    }

    nonisolated static var isAllowed: Bool {
        if ProcessInfo.processInfo.arguments.contains("-no-cloud") { return false }
        return (Bundle.main.object(forInfoDictionaryKey: "ASTERIA_CLOUDKIT") as? String) != "NO"
    }

    var isEnabled: Bool { container != nil }

    var containerIdentifier: String { VaultDisk.containerID }
    var environment: String {
        #if DEBUG
        "Development"
        #else
        "Production"
        #endif
    }

    func isPaused() -> Bool { loadState().paused }

    func pause() {
        var state = loadState()
        state.paused = true
        save(state)
        phase = .paused
        lastMessage = "Sync is paused. This device keeps its own vault."
        lastError = nil
    }

    func resume() {
        var state = loadState()
        state.paused = false
        state.token = nil
        save(state)
        zoneReady = false
        phase = .idle
        lastMessage = "Sync will resume now."
        lastError = nil
    }

    /// Forget the CloudKit change token so the next sync fetches every record.
    /// Used on a new device, after an erase, and by "Sync Everything Again".
    func resetToken() {
        var state = loadState()
        state.token = nil
        save(state)
        zoneReady = false
    }

    func accountStatus() async -> CKAccountStatus {
        guard let container else { return .couldNotDetermine }
        return (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func accountExplanation() async -> String {
        guard isEnabled else { return "iCloud is off for this build" }
        return switch await accountStatus() {
        case .available: "Signed in to iCloud"
        case .noAccount: "Not signed in to iCloud"
        case .restricted: "iCloud is restricted on this device"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        case .couldNotDetermine: "iCloud status could not be read"
        @unknown default: "iCloud status is unknown"
        }
    }

    func lookupHeader() async -> HeaderLookup {
        lastLookupError = nil
        guard isEnabled else {
            lastLookupError = "iCloud is off for this build."
            return .unavailable
        }
        #if DEBUG
        // Reproduces the TestFlight/Production schema failure on a simulator for the blocked-setup UI.
        if ProcessInfo.processInfo.arguments.contains("-cloud-unavailable") {
            lastLookupError = "Keys' CloudKit schema is not deployed in this environment. In CloudKit Console, deploy Header and Item from Development to Production, then try again."
            return .unavailable
        }
        #endif
        guard await accountAvailable() else {
            lastLookupError = "Sign in to iCloud in Settings to keep Keys on all your devices."
            return .unavailable
        }
        let result = await withTaskGroup(of: HeaderLookup.self) { group in
            group.addTask { @MainActor in
                do {
                    if let header = try await self.fetchHeader() { return .found(header) }
                    // No header record is not the same as no schema. In Production, a missing record
                    // type must not become "create a new vault here", which would fork the person's data.
                    if try await self.headerTypeExists() { return .absent }
                    self.lastLookupError = "Keys' CloudKit schema is not deployed in this environment. Deploy Header and Item in CloudKit Console, then try again."
                    return .unavailable
                } catch {
                    self.lastLookupError = Self.friendly(error)
                    return .unavailable
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return .unavailable
            }
            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
        if result == .unavailable, lastLookupError == nil {
            lastLookupError = "iCloud did not answer in time. Check the connection and try again."
        }
        return result
    }

    /// Distinguishes "the Header type exists but has no record" from "this environment has no Keys
    /// schema". The first is a new vault; the second is a released build talking to an undeployed
    /// Production database, and must never invite the person to create a second vault.
    private func headerTypeExists() async throws -> Bool {
        guard let database else { throw VaultError.unavailable }
        let query = CKQuery(recordType: "Header", predicate: NSPredicate(value: true))
        do {
            _ = try await database.records(matching: query, inZoneWith: zoneID,
                                           desiredKeys: [], resultsLimit: 1)
            return true
        } catch let error as CKError {
            let text = error.localizedDescription
            if error.code == .invalidArguments
                || text.contains("Cannot create new type")
                || text.contains("production schema")
                || text.contains("Unknown record type") {
                return false
            }
            throw error
        }
    }

    func replaceWithRemote() async throws {
        guard let header = try await fetchHeader() else { throw VaultError.unavailable }
        var file = VaultFile.empty(header: header)
        file.headerNeedsUpload = false
        try VaultDisk.write(file)
        resume()
        _ = await sync(key: nil)
    }

    func sync(key: Data?) async -> SyncReport {
        guard isEnabled else {
            phase = .unavailable
            lastError = "iCloud is off for this build."
            lastMessage = "iCloud is off for this build."
            return .offline(lastMessage)
        }
        guard !isPaused() else {
            phase = .paused
            return .paused
        }
        guard !inFlight else { return .busy }
        guard await accountAvailable() else {
            phase = .unavailable
            lastError = SyncFailure.noAccount.localizedDescription
            lastMessage = SyncFailure.noAccount.localizedDescription
            return .offline(lastMessage)
        }

        inFlight = true
        phase = .syncing
        lastError = nil
        refreshPending()
        defer { inFlight = false }

        do {
            try await ensureZone()
            try? await ensureSubscription()
            let keptBoth = try await withRetry { try await self.pull(key: key) }
            try await withRetry { try await self.push(key: key) }
            lastSync = .now
            phase = .synced
            lastMessage = keptBoth ? "Synced. A conflict kept both copies." : "Synced through iCloud."
            refreshPending()
            return .synced(lastMessage)
        } catch SyncProblem.mismatch {
            phase = .failed
            lastError = "iCloud has a different Keys vault than this device."
            lastMessage = lastError ?? ""
            return .mismatch
        } catch {
            let message = Self.friendly(error)
            phase = .failed
            lastError = message
            lastMessage = message
            refreshPending()
            return .offline(message)
        }
    }

    func refreshPending() {
        guard let file = VaultDisk.read() else {
            pendingUploads = 0
            pendingDeletes = 0
            return
        }
        pendingUploads = file.records.filter { $0.needsUpload && !$0.needsDelete }.count
            + (file.headerNeedsUpload ? 1 : 0)
        pendingDeletes = file.records.filter(\.needsDelete).count
    }

    // MARK: - Account and zones

    private func accountAvailable() async -> Bool {
        guard let container else { return false }
        return (try? await container.accountStatus()) == .available
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        guard let database else { throw VaultError.unavailable }
        _ = try await withRetry {
            try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: self.zoneID)], deleting: [])
        }
        zoneReady = true
    }

    private func ensureSubscription() async throws {
        guard let database else { throw VaultError.unavailable }
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "keys-vault")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    func fetchHeader() async throws -> VaultHeader? {
        try await ensureZone()
        guard let database else { throw VaultError.unavailable }
        let id = CKRecord.ID(recordName: headerName, zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            return header(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: - Pull

    private func pull(key: Data?) async throws -> Bool {
        guard let database else { throw VaultError.unavailable }
        var state = loadState()
        var token = state.token.flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        var more = true
        var keptBoth = false
        var restarted = false
        while more {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    if try apply(modification.record, key: key) { keptBoth = true }
                }
                for deletion in changes.deletions {
                    try applyDeletion(deletion.recordID.recordName)
                }
                token = changes.changeToken
                state.token = token.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                save(state)
                more = changes.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired && !restarted {
                restarted = true
                token = nil
                state.token = nil
                save(state)
                continue
            } catch let error as CKError where error.code == .zoneNotFound {
                zoneReady = false
                try await ensureZone()
                continue
            }
        }
        return keptBoth
    }

    @discardableResult
    private func apply(_ record: CKRecord, key: Data?) throws -> Bool {
        if record.recordID.recordName == headerName || record.recordType == "Header" {
            guard let remote = header(from: record) else { return false }
            guard var file = VaultDisk.read() else {
                var created = VaultFile.empty(header: remote)
                created.headerNeedsUpload = false
                created.headerSystemFields = RecordCoding.fields(of: record)
                try VaultDisk.write(created)
                return false
            }
            if !file.header.isSameVault(as: remote) { throw SyncProblem.mismatch }
            file.headerSystemFields = RecordCoding.fields(of: record)
            let remoteIsNewer = (remote.revised ?? .distantPast) > (file.header.revised ?? .distantPast)
            if file.headerNeedsUpload {
                // A password change that has not reached iCloud yet wins until it is uploaded.
                if remoteIsNewer, file.header.wrappedKey != remote.wrappedKey {
                    file.header = remote
                    file.headerNeedsUpload = false
                }
            } else {
                file.header = remote
            }
            try VaultDisk.write(file)
            return false
        }
        guard let id = UUID(uuidString: record.recordID.recordName),
              let ciphertext = record["ciphertext"] as? Data else { return false }
        let revision = record["revision"] as? Date ?? .distantPast
        let fields = RecordCoding.fields(of: record)
        var keptBoth = false
        try VaultDisk.update { file in
            let remote = SealedRecord(
                id: id,
                ciphertext: ciphertext,
                revision: revision,
                systemFields: fields,
                needsUpload: false,
                needsDelete: false
            )
            guard let index = file.records.firstIndex(where: { $0.id == id }) else {
                file.records.append(remote)
                return
            }
            var local = file.records[index]
            if local.needsDelete { return }
            if local.ciphertext == ciphertext {
                local.systemFields = fields
                local.needsUpload = false
                local.revision = revision
                file.records[index] = local
                return
            }
            if !local.needsUpload {
                local.ciphertext = ciphertext
                local.revision = revision
                local.systemFields = fields
                local.needsUpload = false
                file.records[index] = local
                return
            }
            guard let key else { return }
            guard let localItem = try? VaultBox.open(local, key: key),
                  let remoteItem = try? VaultBox.open(remote, key: key) else { return }
            let resolved = VaultBox.resolve(local: localItem, remote: remoteItem)
            if resolved.current.sameSecrets(as: remoteItem) {
                local.ciphertext = ciphertext
                local.revision = remoteItem.revised
                local.needsUpload = false
            } else if let sealed = try? VaultBox.seal(resolved.current, key: key) {
                local.ciphertext = sealed.ciphertext
                local.revision = sealed.revision
                local.needsUpload = true
            }
            local.systemFields = fields
            file.records[index] = local
            if let conflict = resolved.conflict, let sealed = try? VaultBox.seal(conflict, key: key) {
                file.records.append(sealed)
                keptBoth = true
            }
        }
        return keptBoth
    }

    private func applyDeletion(_ name: String) throws {
        guard name != headerName, let id = UUID(uuidString: name) else { return }
        let cutoff = lastSync ?? .distantPast
        try VaultDisk.update { file in
            guard let index = file.records.firstIndex(where: { $0.id == id }) else { return }
            let local = file.records[index]
            // A local edit made after the last successful sync is newer than the deletion we just learned
            // about. Keep it and let the next push restore it. Otherwise the other device's delete wins.
            if local.needsUpload, local.revision > cutoff { return }
            file.records.remove(at: index)
        }
    }

    // MARK: - Push

    private func push(key: Data?) async throws {
        guard let database else { throw VaultError.unavailable }
        guard let file = VaultDisk.read() else { return }
        var saving: [CKRecord] = []
        var deleting: [CKRecord.ID] = []
        var uploaded: [String: Data] = [:]
        if file.headerNeedsUpload {
            let record = RecordCoding.record(type: "Header", name: headerName, zoneID: zoneID, fields: file.headerSystemFields)
            record["salt"] = file.header.salt
            record["iterations"] = file.header.iterations
            record["wrappedKey"] = file.header.wrappedKey
            record["recoveryWrap"] = file.header.recoveryWrap
            record["vaultID"] = file.header.effectiveID
            record["revised"] = file.header.revised ?? .now
            saving.append(record)
            uploaded[headerName] = file.header.wrappedKey
        }
        for item in file.records where item.needsDelete {
            deleting.append(CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID))
        }
        for item in file.records where item.needsUpload && !item.needsDelete {
            let name = item.id.uuidString
            let record = RecordCoding.record(type: "Item", name: name, zoneID: zoneID, fields: item.systemFields)
            record["ciphertext"] = item.ciphertext
            record["revision"] = item.revision
            saving.append(record)
            uploaded[name] = item.ciphertext
        }
        guard !saving.isEmpty || !deleting.isEmpty else { return }

        let chunk = 200
        var start = 0
        var failures: [String] = []
        while start < saving.count || !deleting.isEmpty {
            let saveEnd = min(start + chunk, saving.count)
            let saveSlice = start < saving.count ? Array(saving[start..<saveEnd]) : []
            let deleteSlice = Array(deleting.prefix(chunk))
            deleting.removeFirst(min(chunk, deleting.count))
            start = saveEnd
            if saveSlice.isEmpty && deleteSlice.isEmpty { break }

            do {
                let result = try await database.modifyRecords(
                    saving: saveSlice,
                    deleting: deleteSlice,
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: false
                )
                try VaultDisk.update { file in
                    for (_, saved) in result.saveResults {
                        switch saved {
                        case .success(let record):
                            self.noteSaved(record, uploaded: uploaded, file: &file)
                        case .failure(let error):
                            if let server = self.serverRecord(from: error) {
                                _ = self.mergeConflict(server, key: key, file: &file)
                            } else {
                                failures.append(Self.friendly(error))
                            }
                        }
                    }
                    for (id, deleted) in result.deleteResults {
                        let gone: Bool
                        switch deleted {
                        case .success:
                            gone = true
                        case .failure(let error):
                            if let ck = error as? CKError, ck.code == .unknownItem {
                                gone = true
                            } else {
                                gone = false
                                failures.append(Self.friendly(error))
                            }
                        }
                        if gone, let uuid = UUID(uuidString: id.recordName) {
                            file.records.removeAll { $0.id == uuid && $0.needsDelete }
                        }
                    }
                }
            } catch {
                failures.append(Self.friendly(error))
                break
            }
        }
        if !failures.isEmpty { throw SyncFailure.partial(failures) }
    }

    private func noteSaved(_ record: CKRecord, uploaded: [String: Data], file: inout VaultFile) {
        let name = record.recordID.recordName
        let fields = RecordCoding.fields(of: record)
        if name == headerName {
            if file.header.wrappedKey == uploaded[name] {
                file.headerNeedsUpload = false
                file.headerSystemFields = fields
                if file.header.revised == nil { file.header.revised = record["revised"] as? Date }
            }
            return
        }
        guard let id = UUID(uuidString: name), let index = file.records.firstIndex(where: { $0.id == id }) else { return }
        if file.records[index].ciphertext == uploaded[name] {
            file.records[index].needsUpload = false
            file.records[index].systemFields = fields
        }
    }

    private func serverRecord(from error: Error) -> CKRecord? {
        guard let ck = error as? CKError, ck.code == .serverRecordChanged else { return nil }
        return ck.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }

    @discardableResult
    private func mergeConflict(_ server: CKRecord, key: Data?, file: inout VaultFile) -> Bool {
        guard let key else { return false }
        if server.recordID.recordName == headerName, let remote = header(from: server) {
            if !file.header.isSameVault(as: remote) { return false }
            file.headerSystemFields = RecordCoding.fields(of: server)
            let remoteIsNewer = (remote.revised ?? .distantPast) > (file.header.revised ?? .distantPast)
            if remoteIsNewer, file.header.wrappedKey != remote.wrappedKey {
                file.header = remote
                file.headerNeedsUpload = false
            } else if file.header.wrappedKey == remote.wrappedKey {
                file.headerNeedsUpload = false
            }
            return false
        }
        guard let id = UUID(uuidString: server.recordID.recordName),
              let ciphertext = server["ciphertext"] as? Data,
              let index = file.records.firstIndex(where: { $0.id == id }) else { return false }
        let remote = SealedRecord(
            id: id,
            ciphertext: ciphertext,
            revision: server["revision"] as? Date ?? .distantPast,
            systemFields: RecordCoding.fields(of: server),
            needsUpload: false,
            needsDelete: false
        )
        guard let localItem = try? VaultBox.open(file.records[index], key: key),
              let remoteItem = try? VaultBox.open(remote, key: key) else { return false }
        let resolved = VaultBox.resolve(local: localItem, remote: remoteItem)
        var local = file.records[index]
        local.systemFields = remote.systemFields
        if resolved.current.sameSecrets(as: remoteItem) {
            local.ciphertext = ciphertext
            local.revision = remoteItem.revised
            local.needsUpload = false
        } else if let sealed = try? VaultBox.seal(resolved.current, key: key) {
            local.ciphertext = sealed.ciphertext
            local.revision = sealed.revision
            local.needsUpload = true
        }
        file.records[index] = local
        if let conflict = resolved.conflict, let sealed = try? VaultBox.seal(conflict, key: key) {
            file.records.append(sealed)
            return true
        }
        return false
    }

    // MARK: - Header, retry, errors

    private func header(from record: CKRecord) -> VaultHeader? {
        guard let salt = record["salt"] as? Data,
              let wrappedKey = record["wrappedKey"] as? Data,
              let recoveryWrap = record["recoveryWrap"] as? Data else { return nil }
        let iterations = (record["iterations"] as? NSNumber)?.intValue ?? VaultCrypto.iterations
        let vaultID = record["vaultID"] as? String
        return VaultHeader(salt: salt, iterations: iterations, wrappedKey: wrappedKey,
                           recoveryWrap: recoveryWrap, vaultID: vaultID,
                           revised: record["revised"] as? Date)
    }

    private func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await body() }
            catch let error as CKError where Self.isTransient(error) && attempt < 3 {
                attempt += 1
                let suggested = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
                let delay = min(30, suggested ?? pow(2, Double(attempt)))
                try? await Task.sleep(for: .seconds(delay))
                if error.code == .zoneNotFound { zoneReady = false }
            }
        }
    }

    private static func isTransient(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .internalError, .accountTemporarilyUnavailable, .zoneNotFound:
            return true
        default:
            return false
        }
    }

    static func friendly(_ error: Error) -> String {
        if let error = error as? SyncFailure { return error.localizedDescription }
        if let error = error as? CKError {
            let text = error.localizedDescription
            if text.contains("Cannot create new type") || text.contains("production schema")
                || text.contains("Unknown record type") {
                return "Keys' CloudKit schema is not deployed in this environment. In CloudKit Console, deploy Header and Item from Development to Production, then try again."
            }
            switch error.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                return "Sign in to iCloud in Settings to keep Keys on all your devices."
            case .networkUnavailable, .networkFailure:
                return "Keys can't reach iCloud right now. Your vault stays on this device and will sync when the network is back."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free some space, then sync again."
            case .zoneNotFound:
                return "Keys is still setting up its iCloud zone. Try again in a moment."
            case .serverRecordChanged:
                return "An item changed on another device. Keys kept both copies."
            case .requestRateLimited, .zoneBusy:
                return "iCloud is busy. Keys will try again shortly."
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? VaultError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }

    // MARK: - State

    private struct SyncState: Codable {
        var token: Data?
        var paused: Bool
    }

    private func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: VaultDisk.syncStateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState(token: nil, paused: false)
        }
        return state
    }

    private func save(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: VaultDisk.directory, withIntermediateDirectories: true)
        try? data.write(to: VaultDisk.syncStateURL, options: .atomic)
    }
}

private enum RecordCoding {
    static func fields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(type: String, name: String, zoneID: CKRecordZone.ID, fields: Data?) -> CKRecord {
        if let fields, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver) {
                unarchiver.finishDecoding()
                return record
            }
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }
}
