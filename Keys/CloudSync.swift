import CloudKit
import Foundation
import Observation

enum HeaderLookup: Sendable {
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
    private(set) var pendingUploads = 0
    private(set) var pendingDeletes = 0

    private let container = CKContainer(identifier: VaultDisk.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: VaultDisk.zoneName, ownerName: CKCurrentUserDefaultName)
    private let headerName = "header"
    private var inFlight = false
    private var zoneReady = false

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

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func accountExplanation() async -> String {
        switch await accountStatus() {
        case .available: "Signed in to iCloud"
        case .noAccount: "Not signed in to iCloud"
        case .restricted: "iCloud is restricted on this device"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        case .couldNotDetermine: "iCloud status could not be read"
        @unknown default: "iCloud status is unknown"
        }
    }

    func lookupHeader() async -> HeaderLookup {
        guard await accountAvailable() else { return .unavailable }
        return await withTaskGroup(of: HeaderLookup.self) { group in
            group.addTask { @MainActor in
                do {
                    if let header = try await self.fetchHeader() { return .found(header) }
                    return .absent
                } catch {
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
        (try? await container.accountStatus()) == .available
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await withRetry {
            try await self.database.modifyRecordZones(saving: [CKRecordZone(zoneID: self.zoneID)], deleting: [])
        }
        zoneReady = true
    }

    private func ensureSubscription() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "keys-vault")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    func fetchHeader() async throws -> VaultHeader? {
        try await ensureZone()
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
            if file.header.salt != remote.salt { throw SyncProblem.mismatch }
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
        try VaultDisk.update { file in
            guard let index = file.records.firstIndex(where: { $0.id == id }) else { return }
            if file.records[index].needsUpload { return }
            file.records.remove(at: index)
        }
    }

    // MARK: - Push

    private func push(key: Data?) async throws {
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
            if file.header.salt != remote.salt { return false }
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
        return VaultHeader(salt: salt, iterations: iterations, wrappedKey: wrappedKey,
                           recoveryWrap: recoveryWrap, revised: record["revised"] as? Date)
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
