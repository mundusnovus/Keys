import AppIntents
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(KeysPreferences.self) private var preferences
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var initialPane: SettingsPane = .general

    @State private var path: [SettingsPane] = []

    var body: some View {
        NavigationStack(path: $path) {
            settingsList
                .navigationTitle("Settings")
                .navigationDestination(for: SettingsPane.self) { pane in
                    SettingsPaneView(pane: pane)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(preferences.accent.color)
        .onAppear {
            if path.isEmpty, initialPane != .general { path = [initialPane] }
        }
        #if os(macOS)
        .frame(minWidth: 660, minHeight: 620)
        #endif
    }

    private var settingsList: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Wordmark(size: 28)
                    Spacer()
                    Text("2.0").font(.reading(.caption, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: session.syncPhase.symbol,
                             color: session.syncPhase == .failed ? Palette.alert : Palette.sea)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.syncPhase.label).font(.reading(.body, weight: .semibold))
                        Text(session.syncMessage).font(.reading(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button {
                        Task { await session.syncNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise").symbol()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Sync now")
                }
            }

            Section("Settings") {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink(value: pane) {
                        SettingsRow(pane: pane)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keys keeps your vault encrypted on this device and stores only ciphertext in your own iCloud.")
                        .font(.reading(.caption))
                        .foregroundStyle(.secondary)
                    Text("No Asteria server. No analytics. No password ever leaves your devices.")
                        .font(.reading(.caption2))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }
}

struct SettingsPaneView: View {
    var pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralSettingsPane()
            case .security: SecuritySettingsPane()
            case .sync: SyncSettingsPane()
            case .autofill: AutoFillSettingsPane()
            case .intelligence: IntelligenceSettingsPane()
            case .siri: SiriSettingsPane()
            case .data: DataSettingsPane()
            case .about: AboutSettingsPane()
            }
        }
        .navigationTitle(pane.title)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(KeysPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)], spacing: 10) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            preferences.accent = choice
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(choice.color).frame(width: 30, height: 30)
                                    if preferences.accent == choice {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(choice.name).font(.reading(.caption2, weight: .medium))
                                    .foregroundStyle(preferences.accent == choice ? Color.primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(preferences.accent == choice ? choice.color.opacity(0.12) : .clear,
                                        in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(choice.name) accent")
                        .accessibilityAddTraits(preferences.accent == choice ? .isSelected : [])
                    }
                }
            } header: {
                Text("Accent")
            } footer: {
                Text("The accent follows you through iCloud and keeps 4.5:1 contrast in light and dark.")
            }

            Section("Glass") {
                Picker("Style", selection: $preferences.glassStyle) {
                    ForEach(GlassStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(preferences.glassStyle.explanation)
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section("Home") {
                Toggle("Show the Siri tip", isOn: $preferences.showSiriTip)
                Text("The tip teaches one phrase. It never shows a secret.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Security

private struct SecuritySettingsPane: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @State private var showChangePassword = false
    @State private var confirmErase = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                if session.biometricsAvailable {
                    Toggle(isOn: Binding(
                        get: { session.biometricsEnabled },
                        set: { on in
                            if on { session.enableBiometrics() } else { session.disableBiometrics() }
                        }
                    )) {
                        Label(FaceIDCopy.name, systemImage: FaceIDCopy.symbol)
                    }
                    if !session.biometricsMessage.isEmpty {
                        Text(session.biometricsMessage).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                    }
                } else {
                    Label("Set a device passcode first", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Unlock")
            } footer: {
                Text("Keys stores the vault key in the keychain behind \(FaceIDCopy.name) or your device passcode. It never leaves this device.")
            }

            Section("Auto-lock") {
                Picker("Lock after", selection: $preferences.autoLock) {
                    ForEach(AutoLockDelay.allCases) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                Text("Keys locks when the app goes to the background. The delay gives you time to copy a code.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Picker("Clear after", selection: $preferences.clipboardClear) {
                    ForEach(ClipboardClear.allCases) { clear in
                        Text(clear.label).tag(clear)
                    }
                }
                Toggle("Ask before showing a secret", isOn: $preferences.requireAuthToReveal)
                Text("Copies are cleared from the clipboard automatically. Keys never speaks a password.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showChangePassword = true
                } label: {
                    Label("Change Master Password", systemImage: "key.horizontal")
                }
                Text("The recovery key from setup stays valid after a change.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    session.lock()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmErase = true
                } label: {
                    Label("Erase This Device's Vault", systemImage: "trash")
                }
                Text("This removes the local vault and the Face ID key. The iCloud copy stays and will come back when you sign in again.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .confirmationDialog("Erase this device's vault?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { session.eraseLocalVault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The iCloud copy is not deleted.")
        }
    }
}

private struct ChangePasswordView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var updated = ""
    @State private var confirm = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current master password", text: $current)
                    SecureField("New master password", text: $updated)
                    SecureField("Confirm new master password", text: $confirm)
                } footer: {
                    Text("Use at least 12 characters. The recovery key stays valid.")
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(Palette.alert) }
                }
                Section {
                    Button {
                        Task {
                            if let problem = await session.changePassword(current: current, newPassword: updated, confirm: confirm) {
                                message = problem
                            } else {
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Change master password", systemImage: "checkmark.shield")
                    }
                    .disabled(current.isEmpty || updated.count < 12 || confirm.isEmpty)
                }
            }
            .navigationTitle("Master Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.accentColor)
        .frame(minWidth: 420, minHeight: 360)
    }
}

// MARK: - Sync

private struct SyncSettingsPane: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: session.syncPhase.symbol).symbol()
                        Text(session.syncPhase.label)
                    }
                }
                LabeledContent("iCloud account", value: session.iCloudAccount)
                if let last = session.lastSync {
                    LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if session.pendingUploads > 0 {
                    LabeledContent("Waiting to upload", value: "\(session.pendingUploads)")
                }
                if let error = session.syncError, !error.isEmpty {
                    Text(error).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Keys stores ciphertext in your private iCloud database. The master password never leaves your devices, so Apple cannot read an item.")
            }

            Section {
                Button {
                    Task { await session.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(session.syncPhase == .syncing)
                if session.syncPhase == .paused {
                    Button {
                        session.resumeSync()
                    } label: {
                        Label("Resume Sync", systemImage: "play.fill")
                    }
                } else {
                    Button(role: .destructive) {
                        session.pauseSync()
                    } label: {
                        Label("Pause Sync on This Device", systemImage: "pause.fill")
                    }
                }
                Button {
                    Task { await session.refreshAccount() }
                } label: {
                    Label("Refresh iCloud Status", systemImage: "icloud")
                }
            }

            Section("Diagnostics") {
                LabeledContent("Container", value: session.syncContainer)
                    .font(.reading(.caption))
                LabeledContent("Environment", value: session.syncEnvironment)
                LabeledContent("Phase", value: session.syncPhase.label)
                LabeledContent("Pending", value: "\(session.pendingUploads) uploads")
                Text("A TestFlight or App Store build uses the Production CloudKit environment. An Xcode build uses Development. They do not see each other until the schema is deployed.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section("What syncs") {
                Text("Logins, notes, cards, identities, Wi-Fi passwords, passkeys, and one-time codes sync inside the encrypted vault.")
                Text("Face ID keys, the clipboard, and this device's auto-lock choice stay on this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AutoFill

private struct AutoFillSettingsPane: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        Form {
            Section {
                LabeledContent("Keys in AutoFill") {
                    StatusPill(text: session.autofillOn ? "On" : "Off",
                               symbol: session.autofillOn ? "checkmark.circle.fill" : "circle",
                               tint: session.autofillOn ? Palette.pass : .secondary)
                }
                Button {
                    openAutoFillSettings()
                } label: {
                    Label("Open AutoFill Settings", systemImage: "gearshape")
                }
                Text("Turn on Keys under AutoFill & Passwords. Keys asks you to unlock before it fills a password, a code, or a passkey.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            } header: {
                Text("AutoFill")
            }

            Section("What Keys can fill") {
                Label("Passwords and usernames", systemImage: "key.fill")
                Label("One-time codes", systemImage: "number.square")
                Label("Passkeys", systemImage: "person.badge.key")
                Label("Wi-Fi passwords are kept in the vault but are not filled by AutoFill.", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("AutoFill reads the same encrypted vault through the app group. It never uploads a credential.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            session.autofillOn = await IdentityPublisher.autofillEnabled()
        }
    }

    private func openAutoFillSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

// MARK: - Intelligence

private struct IntelligenceSettingsPane: View {
    @Environment(KeysPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                LabeledContent("On this device") {
                    StatusPill(text: KeysIntelligence.onDeviceStatus.explanation,
                               symbol: KeysIntelligence.onDeviceStatus.symbol,
                               tint: KeysIntelligence.onDeviceStatus.isReady ? Palette.pass : .secondary)
                }
                LabeledContent("Private Cloud Compute") {
                    StatusPill(text: KeysIntelligence.privateCloudStatus.explanation,
                               symbol: KeysIntelligence.privateCloudStatus.symbol,
                               tint: KeysIntelligence.privateCloudStatus.isReady ? Palette.sea : .secondary)
                }
                if KeysIntelligence.privateCloudEntitled {
                    LabeledContent("Daily quota", value: KeysIntelligence.privateCloudQuota)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Keys uses Apple Intelligence for drafting a login, explaining security findings, and turning a sentence into search filters.")
            }

            Section("Features") {
                Toggle("Apple Intelligence", isOn: $preferences.intelligenceEnabled)
                Toggle("Capture from a sentence", isOn: $preferences.captureEnabled)
                    .disabled(!preferences.intelligenceEnabled)
                Toggle("Security coach", isOn: $preferences.securityCoachEnabled)
                    .disabled(!preferences.intelligenceEnabled)
                Toggle("Apple Intelligence search", isOn: $preferences.smartSearchEnabled)
                    .disabled(!preferences.intelligenceEnabled)
            }

            Section("Private Cloud Compute") {
                Toggle("Use Apple's servers for the security coach", isOn: $preferences.usePrivateCloudCompute)
                    .disabled(!KeysIntelligence.privateCloudEntitled || !preferences.intelligenceEnabled)
                Text("Private Cloud Compute is Apple's server-side Apple Intelligence. It is used only for the security coach, and only with counts of findings. Capture and search stay on this device.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
                if !KeysIntelligence.privateCloudEntitled {
                    Text("This build does not have Apple's managed Private Cloud Compute entitlement. The app falls back to the on-device model. Request access from Apple, then add the entitlement to both configurations.")
                        .font(.reading(.footnote))
                        .foregroundStyle(.secondary)
                    if let url = URL(string: "https://developer.apple.com/private-cloud-compute/") {
                        Link("Request Private Cloud Compute access", destination: url)
                            .font(.reading(.footnote))
                    }
                }
            }

            Section("What Apple Intelligence never sees") {
                Text("Passwords, usernames, site names, notes, card numbers, one-time codes, recovery keys, and passkey private keys.")
                Text("Capture and smart search run on this device. The coach receives counts and finding kinds only.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Siri

private struct SiriSettingsPane: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences

    private let phrases = [
        "Open Asteria Keys",
        "Find in Asteria Keys",
        "Open GitHub in Asteria Keys",
        "Generate a password in Asteria Keys",
        "Lock Asteria Keys",
    ]

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Share item names with Siri and Spotlight", isOn: $preferences.shareWithSiri)
                Text("Only titles and sites are indexed. Passwords, usernames, notes, and codes are never indexed.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Siri & Spotlight")
            } footer: {
                Text("Turning this off deletes every indexed item, not just future ones.")
            }

            Section("Shortcuts") {
                ForEach(phrases, id: \.self) { phrase in
                    Label(phrase, systemImage: "waveform")
                        .font(.reading(.body))
                }
                #if os(iOS)
                ShortcutsLink()
                #endif
            }

            Section("Handoff") {
                Text("The item on screen continues on your other devices. Handoff carries the item's identity, never its secrets.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Siri can open an item, search the vault, generate a password, lock the vault, and check how many items need review. It never speaks a password.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.shareWithSiri) { _, allowed in
            Task {
                if allowed {
                    await SpotlightIndex.reindex(session.items, allowed: true)
                } else {
                    await SpotlightIndex.removeAll()
                }
            }
        }
    }
}

// MARK: - Data

private struct DataSettingsPane: View {
    @Environment(VaultSession.self) private var session
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: DataFile?
    @State private var importReview: ImportReview?
    @State private var confirmCSV = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Items", value: "\(session.liveCount)")
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: session.storageBytes, countStyle: .file))
                LabeledContent("Trash", value: "\(session.trashCount)")
            } header: {
                Text("This Vault")
            }

            Section("Import") {
                Button {
                    importing = true
                } label: {
                    Label("Import CSV or Bitwarden JSON", systemImage: "square.and.arrow.down")
                }
                Text("Duplicates already in the vault are skipped. Cancel writes nothing.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Button {
                    exportEncrypted()
                } label: {
                    Label("Export Encrypted Vault", systemImage: "lock.doc")
                }
                Button(role: .destructive) {
                    confirmCSV = true
                } label: {
                    Label("Export Plaintext CSV", systemImage: "doc.text")
                }
                Text("The encrypted export needs your master password to open. The CSV is readable by anyone.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            if !message.isEmpty {
                Section { Text(message).font(.reading(.footnote)).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.commaSeparatedText, .json, .plainText, .data]) { result in
            handleImport(result)
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .data,
                      defaultFilename: exportFile?.filename ?? "Keys.vault") { _ in
            exportFile = nil
        }
        .sheet(item: $importReview) { review in
            NavigationStack {
                VStack(spacing: 16) {
                    Text("\(review.items.count) items").font(.reading(.title3, weight: .semibold))
                    Text("Duplicates already in the vault are skipped. Cancel writes nothing.")
                        .font(.reading(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .navigationTitle("Import")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { importReview = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            message = session.importItems(review.items)
                            importReview = nil
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .frame(minWidth: 380, minHeight: 260)
        }
        .confirmationDialog("Export passwords as plaintext?", isPresented: $confirmCSV, titleVisibility: .visible) {
            Button("Export Plaintext CSV", role: .destructive) { exportCSV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file contains passwords anyone can read.")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            message = "That file could not be read."
            return
        }
        do {
            importReview = ImportReview(items: try parseImport(data))
        } catch {
            message = error.localizedDescription
        }
    }

    private func parseImport(_ data: Data) throws -> [VaultItem] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["items"] != nil || json["folders"] != nil || json["encrypted"] != nil {
            return try VaultTransfer.parseBitwarden(data)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.file }
        let items = VaultTransfer.parseCSV(text)
        if items.isEmpty { throw VaultError.file }
        return items
    }

    private func exportEncrypted() {
        guard let data = session.encryptedExport() else { return }
        exportFile = DataFile(data: data, filename: "Keys.vault")
        exporting = true
    }

    private func exportCSV() {
        exportFile = DataFile(data: Data(session.plaintextCSV().utf8), filename: "Keys.csv")
        exporting = true
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Wordmark(size: 34)
                    Text("Asteria Keys \(version)").font(.reading(.headline, weight: .semibold))
                    Text("Build \(build)").font(.reading(.caption)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Privacy") {
                Text("Keys encrypts your vault with AES-GCM and a key wrapped by your master password. Only ciphertext goes to your private iCloud database. There is no Asteria server, no analytics, and no advertising.")
                Text("Apple Intelligence receives counts and finding kinds only. Capture and smart search run on this device.")
                    .foregroundStyle(.secondary)
            }

            Section("Licence") {
                Text("Asteria License 1.0. The Asteria Pixel font is used for the wordmark only. Text a person sets in it stays theirs.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section("Made by") {
                Text("Asteria Technology")
                Text("Modern Swift apps for iPhone, iPad, and Mac.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Import/export helpers

struct ImportReview: Identifiable {
    var id = UUID()
    var items: [VaultItem]
}

struct DataFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    var filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = "Keys.vault"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
