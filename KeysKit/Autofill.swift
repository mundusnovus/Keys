import AuthenticationServices
import LocalAuthentication
import SwiftUI

@MainActor @Observable
final class AutofillModel {
    var password = ""
    var message = ""
    var unlocked = false
    var services: [String] = []
    var codesOnly = false
    private(set) var items: [VaultItem] = []
    private var key: Data?

    var visible: [VaultItem] {
        let live = items.filter { item in
            guard item.deleted == nil, item.kind != .folder, item.kind != .note, item.kind != .passkey else { return false }
            if codesOnly, item.totp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return true
        }
        let matched = live.filter { item in
            services.isEmpty || services.contains { item.matches(service: $0) }
        }
        return (matched.isEmpty ? live : matched).sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    func noteServices(_ identifiers: [ASCredentialServiceIdentifier]) {
        services = identifiers.map { identifier in
            if identifier.type == .URL, let host = VaultLink.host(of: identifier.identifier) {
                return host
            }
            return identifier.identifier
        }
    }

    func unlock() async {
        guard let file = VaultDisk.read() else {
            message = "Open Keys and create the vault first."
            return
        }
        let typed = password
        let header = file.header
        do {
            let opened = try await Task.detached {
                try VaultCrypto.unlock(password: typed, header: header)
            }.value
            try await apply(key: opened, file: file)
            password = ""
            message = ""
            try? DeviceKey.save(opened)
        } catch {
            message = "That password does not open this vault."
        }
    }

    func biometric() async {
        let context = LAContext()
        context.localizedReason = "Unlock Keys"
        guard let opened = DeviceKey.load(context: context), let file = VaultDisk.read() else {
            message = "Use the master password on this device once."
            return
        }
        do {
            try await apply(key: opened, file: file)
            message = ""
        } catch {
            message = "The vault on this device could not be opened."
        }
    }

    func silentKey() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        return DeviceKey.load(context: context)
    }

    @discardableResult
    func unlockSilently() -> Bool {
        guard let opened = silentKey(), let file = VaultDisk.read() else { return false }
        guard let openedItems = try? VaultBox.openAll(file, key: opened) else { return false }
        key = opened
        items = openedItems
        unlocked = true
        return true
    }

    func item(record: String?) -> VaultItem? {
        guard let record, let id = UUID(uuidString: record) else { return nil }
        return items.first { $0.id == id && $0.deleted == nil }
    }

    func prepareAssertion(record: String?, clientDataHash: Data) -> (item: VaultItem, signature: Data, authenticatorData: Data)? {
        guard var item = item(record: record), item.kind == .passkey, !item.privateKey.isEmpty else { return nil }
        guard let signed = try? PasskeyBox.assertion(item: &item, clientDataHash: clientDataHash) else { return nil }
        item.revised = Date()
        store(item)
        return (item, signed.signature, signed.authenticatorData)
    }

    func register(relyingParty: String, username: String, clientDataHash: Data) -> (credentialID: Data, attestation: Data)? {
        guard !relyingParty.isEmpty,
              let material = try? PasskeyBox.generate(relyingParty: relyingParty, username: username),
              let attestation = try? PasskeyBox.registration(material: material, clientDataHash: clientDataHash) else { return nil }
        var item = VaultItem(kind: .passkey)
        item.title = relyingParty
        item.username = username.isEmpty ? relyingParty : username
        item.relyingParty = relyingParty
        item.userHandle = material.userHandle
        item.credentialID = material.credentialID
        item.privateKey = material.privateKey
        item.revised = Date()
        store(item)
        return (material.credentialID, attestation)
    }

    func renamePasskey(relyingParty: String, userHandle: Data, newName: String) {
        guard unlockSilently() else { return }
        guard let index = items.firstIndex(where: {
            $0.kind == .passkey && $0.deleted == nil && $0.relyingParty == relyingParty && $0.userHandle == userHandle
        }) else { return }
        items[index].username = newName
        items[index].revised = Date()
        store(items[index])
    }

    func hideUnknownPasskey(relyingParty: String, credentialID: Data) {
        guard unlockSilently() else { return }
        guard let index = items.firstIndex(where: {
            $0.kind == .passkey && $0.deleted == nil && $0.relyingParty == relyingParty && $0.credentialID == credentialID
        }) else { return }
        items[index].deleted = Date()
        items[index].revised = Date()
        store(items[index])
    }

    private func apply(key opened: Data, file: VaultFile) async throws {
        let openedItems = try await Task.detached {
            try VaultBox.openAll(file, key: opened)
        }.value
        key = opened
        items = openedItems
        unlocked = true
    }

    private func store(_ item: VaultItem) {
        guard let key else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        try? VaultDisk.update { file in
            guard let sealed = try? VaultBox.seal(item, key: key) else { return }
            if let index = file.records.firstIndex(where: { $0.id == item.id }) {
                var record = sealed
                record.systemFields = file.records[index].systemFields
                file.records[index] = record
            } else {
                file.records.append(sealed)
            }
        }
    }
}

enum AutofillRequest {
    case password(record: String?)
    case passkey(record: String?, hash: Data)
    case code(record: String?)
    case register(party: String, username: String, hash: Data)
    case unknown

    static func parse(_ request: any ASCredentialRequest, registration: Bool) -> AutofillRequest {
        if let passkey = request as? ASPasskeyCredentialRequest {
            let identity = passkey.credentialIdentity as? ASPasskeyCredentialIdentity
            if registration {
                return .register(
                    party: identity?.relyingPartyIdentifier ?? "",
                    username: identity?.userName ?? "",
                    hash: passkey.clientDataHash
                )
            }
            return .passkey(record: identity?.recordIdentifier, hash: passkey.clientDataHash)
        }
        if let password = request as? ASPasswordCredentialRequest {
            let identity = password.credentialIdentity as? ASPasswordCredentialIdentity
            return .password(record: identity?.recordIdentifier)
        }
        if let code = request as? ASOneTimeCodeCredentialRequest {
            let identity = code.credentialIdentity as? ASOneTimeCodeCredentialIdentity
            return .code(record: identity?.recordIdentifier)
        }
        return .unknown
    }
}

enum FillResult {
    case password(user: String, password: String)
    case passkey(userHandle: Data, party: String, signature: Data, hash: Data, authenticatorData: Data, credentialID: Data)
    case code(String)
    case registration(party: String, hash: Data, credentialID: Data, attestation: Data)
    case needsUI
    case missing
}

@MainActor
final class CredentialFiller {
    let model = AutofillModel()
    private var pending: AutofillRequest?

    func prepareList(_ identifiers: [ASCredentialServiceIdentifier], codesOnly: Bool) {
        model.noteServices(identifiers)
        model.codesOnly = codesOnly
        pending = nil
    }

    func prepare(_ request: any ASCredentialRequest, registration: Bool) {
        pending = AutofillRequest.parse(request, registration: registration)
    }

    func silent(_ request: any ASCredentialRequest, registration: Bool) -> FillResult {
        pending = AutofillRequest.parse(request, registration: registration)
        guard model.unlockSilently() else { return .needsUI }
        return fulfill()
    }

    func conditional(_ request: ASPasskeyCredentialRequest) -> FillResult {
        pending = AutofillRequest.parse(request, registration: true)
        guard model.unlockSilently() else { return .missing }
        guard case .register(let party, let username, _) = pending else { return .missing }
        let hasLogin = model.visible.contains { item in
            item.kind == .login && item.username == username && item.matches(service: party)
        }
        let hasPasskey = model.items.contains { item in
            item.deleted == nil && item.kind == .passkey && item.relyingParty == party && item.username == username
        }
        guard hasLogin, !hasPasskey else { return .missing }
        return fulfill()
    }

    func afterUnlock() -> FillResult? {
        guard model.unlocked, pending != nil else { return nil }
        let result = fulfill()
        if case .needsUI = result { return nil }
        return result
    }

    func selected(_ item: VaultItem) -> FillResult {
        if model.codesOnly {
            guard let code = OneTimeCode.code(secret: item.totp) else { return .missing }
            return .code(code)
        }
        guard !item.password.isEmpty else { return .missing }
        return .password(user: item.username, password: item.password)
    }

    private func fulfill() -> FillResult {
        switch pending {
        case .password(let record):
            guard let item = model.item(record: record), !item.password.isEmpty else { return .missing }
            return .password(user: item.username, password: item.password)
        case .passkey(let record, let hash):
            guard let signed = model.prepareAssertion(record: record, clientDataHash: hash) else { return .missing }
            return .passkey(
                userHandle: signed.item.userHandle,
                party: signed.item.relyingParty,
                signature: signed.signature,
                hash: hash,
                authenticatorData: signed.authenticatorData,
                credentialID: signed.item.credentialID
            )
        case .code(let record):
            guard let item = model.item(record: record), let code = OneTimeCode.code(secret: item.totp) else { return .missing }
            return .code(code)
        case .register(let party, let username, let hash):
            guard let created = model.register(relyingParty: party, username: username, clientDataHash: hash) else { return .missing }
            return .registration(party: party, hash: hash, credentialID: created.credentialID, attestation: created.attestation)
        case .unknown, nil:
            return .missing
        }
    }
}

struct AutofillPicker: View {
    @Bindable var model: AutofillModel
    var onSelect: (VaultItem) -> Void
    var onCancel: () -> Void
    var onUnlock: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.unlocked {
                    List(model.visible) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayTitle).font(.body.weight(.semibold))
                                Text(item.username.isEmpty ? item.primaryHost : item.username)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 16) {
                        Text("Asteria").font(.custom("Asteria Pixel", size: 28))
                        Text("Keys").font(.title3.weight(.semibold))
                        SecureField("Master password", text: $model.password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.unlock() } }
                        Button("Unlock") { Task { await model.unlock() } }
                            .buttonStyle(.borderedProminent)
                        Button("Use Face ID or Touch ID") { Task { await model.biometric() } }
                        if !model.message.isEmpty {
                            Text(model.message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(model.codesOnly ? "Codes" : "Keys")
            .toolbar {
                Button("Cancel", action: onCancel)
            }
        }
        .frame(minWidth: 340, minHeight: 460)
        .tint(Color(red: 1, green: 0, blue: 88.0 / 255))
        .onChange(of: model.unlocked) { _, unlocked in
            if unlocked { onUnlock() }
        }
    }
}
