import CloudKit
import Foundation

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
}

private enum SyncProblem: Error {
    case mismatch
}

/// iCloud private database. Records hold ciphertext. The master password is never uploaded.
@MainActor
final class CloudSync {
    private let container = CKContainer(identifier: VaultDisk.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: VaultDisk.zoneName, ownerName: CKCurrentUserDefaultName)
    private let headerName = "header"

    func isPaused() -> Bool { loadState().paused }

    func pause() {
        var state = loadState()
        state.paused = true
        save(state)
    }

    func resume() {
        var state = loadState()
        state.paused = false
        state.token = nil
        save(state)
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
                try? await Task.sleep(for: .seconds(20))
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
        if isPaused() { return .paused }
        guard await accountAvailable() else {
            return .offline("iCloud is not available. This vault stays on this device until it is.")
        }
        do {
            try await ensureZone()
            try? await ensureSubscription()
            let keptBoth = try await pull(key: key)
            try await push(key: key)
            if keptBoth {
                return .synced("Synced. A conflict kept both copies.")
            }
            return .synced("Synced through iCloud.")
        } catch SyncProblem.mismatch {
            return .mismatch
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    private func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    private func ensureZone() async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
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

    private func pull(key: Data?) async throws -> Bool {
        var state = loadState()
        var token = state.token.flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        var more = true
        var keptBoth = false
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result else { continue }
                if try apply(modification.record, key: key) { keptBoth = true }
            }
            for deletion in changes.deletions {
                try applyDeletion(deletion.recordID.recordName)
            }
            token = changes.changeToken
            if let token {
                state.token = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            } else {
                state.token = nil
            }
            save(state)
            more = changes.moreComing
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
            if !file.headerNeedsUpload || file.header.wrappedKey == remote.wrappedKey {
                file.header = remote
                file.headerNeedsUpload = false
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
        let chunk = 200
        var start = 0
        while start < saving.count || !deleting.isEmpty {
            let saveEnd = min(start + chunk, saving.count)
            let saveSlice = start < saving.count ? Array(saving[start..<saveEnd]) : []
            let deleteSlice = deleting.prefix(chunk)
            deleting.removeFirst(min(chunk, deleting.count))
            start = saveEnd
            if saveSlice.isEmpty && deleteSlice.isEmpty { break }
            let result = try await database.modifyRecords(
                saving: saveSlice,
                deleting: Array(deleteSlice),
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
                        }
                    }
                }
                for (id, deleted) in result.deleteResults {
                    let gone: Bool
                    if case .success = deleted {
                        gone = true
                    } else if case .failure(let error) = deleted, let ck = error as? CKError, ck.code == .unknownItem {
                        gone = true
                    } else {
                        gone = false
                    }
                    if gone, let uuid = UUID(uuidString: id.recordName) {
                        file.records.removeAll { $0.id == uuid && $0.needsDelete }
                    }
                }
            }
        }
    }

    private func noteSaved(_ record: CKRecord, uploaded: [String: Data], file: inout VaultFile) {
        let name = record.recordID.recordName
        let fields = RecordCoding.fields(of: record)
        if name == headerName {
            if file.header.wrappedKey == uploaded[name] {
                file.headerNeedsUpload = false
                file.headerSystemFields = fields
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
            if file.header.wrappedKey == remote.wrappedKey {
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

    private func header(from record: CKRecord) -> VaultHeader? {
        guard let salt = record["salt"] as? Data,
              let wrappedKey = record["wrappedKey"] as? Data,
              let recoveryWrap = record["recoveryWrap"] as? Data else { return nil }
        let iterations = (record["iterations"] as? NSNumber)?.intValue ?? VaultCrypto.iterations
        return VaultHeader(salt: salt, iterations: iterations, wrappedKey: wrappedKey, recoveryWrap: recoveryWrap)
    }

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
