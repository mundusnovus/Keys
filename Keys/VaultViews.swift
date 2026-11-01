import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

struct VaultRoot: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .loading: ProgressView("Opening Keys").font(.reading(.body))
            case .setup: SetupView()
            case .recovery: RecoveryView()
            case .locked: LockView()
            case .mismatch: MismatchView()
            case .unlocked: VaultSplit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.asteriaAccent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.lock() }
        }
    }
}

struct LockView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 20) {
            Wordmark()
            VStack(spacing: 12) {
                SecureField("Master password", text: $session.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await session.unlock() } }
                Button("Unlock") { Task { await session.unlock() } }
                    .buttonStyle(.glassProminent)
                    .disabled(session.working || session.password.isEmpty)
                Button("Use Face ID or Touch ID") { Task { await session.unlockBiometric() } }
                if !session.message.isEmpty {
                    Text(session.message).font(.reading(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}

struct SetupView: View {
    @Environment(VaultSession.self) private var session
    @State private var confirm = ""

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 20) {
            Wordmark()
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a master password. Keys cannot reset it. A recovery key is shown once, on the next screen.")
                    .font(.reading(.callout))
                    .foregroundStyle(.secondary)
                SecureField("Master password", text: $session.password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm master password", text: $confirm)
                    .textFieldStyle(.roundedBorder)
                Button("Create vault") { Task { await session.create(password: session.password, confirm: confirm) } }
                    .buttonStyle(.glassProminent)
                    .disabled(session.working)
                if !session.message.isEmpty {
                    Text(session.message).font(.reading(.footnote)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
}

struct RecoveryView: View {
    @Environment(VaultSession.self) private var session
    @State private var saved = false

    var body: some View {
        VStack(spacing: 20) {
            Wordmark(size: 28)
            VStack(alignment: .leading, spacing: 14) {
                Text("Save this recovery key. Keys shows it once. Without it, a forgotten master password cannot be recovered.")
                    .font(.reading(.callout))
                Text(session.recovery)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.asteriaCream.opacity(0.35), in: .rect(cornerRadius: 12))
                Button("Copy recovery key") { session.copy(session.recovery) }
                Toggle("I have saved this recovery key", isOn: $saved)
                    .font(.reading(.body))
                Button("Continue") { session.acknowledgeRecovery() }
                    .buttonStyle(.glassProminent)
                    .disabled(!saved)
            }
            .padding(24)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(28)
        .frame(maxWidth: 520)
    }
}

struct MismatchView: View {
    @Environment(VaultSession.self) private var session
    @State private var confirmReplace = false

    var body: some View {
        VStack(spacing: 20) {
            Wordmark()
            VStack(alignment: .leading, spacing: 14) {
                Text("iCloud has a different Keys vault than this device. Keys will not merge two master passwords.")
                    .font(.reading(.body))
                Button("Keep this device's vault") { session.keepLocalVault() }
                    .buttonStyle(.glassProminent)
                Button("Open the iCloud vault", role: .destructive) { confirmReplace = true }
                Text("Opening the iCloud vault removes the vault that exists only on this device.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(28)
        .frame(maxWidth: 520)
        .confirmationDialog("Open the iCloud vault?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace this device's vault", role: .destructive) { Task { await session.useICloudVault() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items stored only on this device will be removed.")
        }
    }
}

struct VaultSplit: View {
    @Environment(VaultSession.self) private var session
    @State private var filter: VaultFilter = .all
    @State private var selection: UUID?
    @State private var query = ""
    @State private var draft: VaultItem?
    @State private var showGenerator = false
    @State private var showCapture = false
    @State private var showSettings = false
    @State private var pendingDelete: UUID?
    @State private var confirmEmpty = false

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarFilter) {
                Section("Vault") {
                    Label("All", systemImage: "square.grid.2x2").tag(VaultFilter.all)
                    Label("Favorites", systemImage: "star").tag(VaultFilter.favorites)
                    Label("Health", systemImage: "checkmark.shield").tag(VaultFilter.health)
                }
                Section("Types") {
                    ForEach(ItemKind.allCases.filter { $0 != .folder }) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(VaultFilter.kind(kind))
                    }
                }
                if !session.folders.isEmpty {
                    Section("Folders") {
                        ForEach(session.folders) { folder in
                            Label(folder.displayTitle, systemImage: "folder").tag(VaultFilter.folder(folder.id))
                        }
                    }
                }
                Section {
                    Label("Trash", systemImage: "trash").tag(VaultFilter.trash)
                }
            }
            .navigationTitle("Keys")
        } content: {
            if filter == .health {
                AuditList(selection: $selection)
            } else {
                itemList
            }
        } detail: {
            if let item = session.items.first(where: { $0.id == selection }) {
                ItemEditor(item: item) { session.save($0) } onDelete: {
                    session.delete(item.id)
                    selection = nil
                }
            } else {
                ContentUnavailableView {
                    Label("Keys", systemImage: "key")
                } description: {
                    Text("Select an item, or add one.")
                }
            }
        }
        .sheet(item: $draft) { item in
            NavigationStack {
                ItemEditor(item: item, isNew: true) {
                    session.save($0)
                    selection = $0.id
                    draft = nil
                } onDelete: { draft = nil }
            }
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorSheet(onUse: nil)
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet { session.save($0) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog("Delete this item?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { session.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It moves to Trash. Empty Trash removes it from this vault and from iCloud.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { session.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These items are removed from this vault and from iCloud.")
        }
    }

    /// iOS only accepts an optional list selection. The sidebar always keeps a filter.
    private var sidebarFilter: Binding<VaultFilter?> {
        Binding {
            filter
        } set: { next in
            if let next { filter = next }
        }
    }

    private var itemList: some View {
        List(session.visible(filter: filter, query: query), selection: $selection) { item in
            ItemRow(item: item)
                .tag(item.id)
                .contextMenu {
                    Button(item.favorite ? "Remove favorite" : "Favorite") { session.toggleFavorite(item.id) }
                    Button("Delete", role: .destructive) { pendingDelete = item.id }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = item.id }
                }
        }
        .searchable(text: $query, prompt: "Names, usernames, sites")
        .navigationTitle(title)
        .toolbar { listToolbar }
        .overlay {
            if session.visible(filter: filter, query: query).isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "key", description: Text(emptyCopy))
            }
        }
    }

    private var title: String {
        switch filter {
        case .all: "All"
        case .favorites: "Favorites"
        case .trash: "Trash"
        case .health: "Health"
        case .kind(let kind): kind.label
        case .folder(let id): session.folders.first { $0.id == id }?.displayTitle ?? "Folder"
        }
    }

    private var emptyCopy: String {
        filter == .trash ? "Deleted items wait here until you empty Trash." : "Add a login, a note, or a card."
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ItemKind.allCases.filter { $0 != .passkey }) { kind in
                    Button(kind.label, systemImage: kind.symbol) { draft = VaultItem(kind: kind) }
                }
                Divider()
                Button("Generate password", systemImage: "wand.and.stars") { showGenerator = true }
                Button("Capture", systemImage: "apple.intelligence") { showCapture = true }
                    .disabled(!CaptureService.available)
            } label: {
                Image(systemName: "plus").symbol()
            }
        }
        ToolbarItem(placement: .automatic) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        if filter == .trash {
            ToolbarItem(placement: .destructiveAction) {
                Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                    .disabled(session.visible(filter: .trash, query: "").isEmpty)
            }
        }
    }
}

struct ItemRow: View {
    var item: VaultItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).font(.reading(.body, weight: .semibold))
                Text(subtitle).font(.reading(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: item.kind.symbol).symbol().foregroundStyle(Color.asteriaAccent)
        }
    }

    private var subtitle: String {
        if !item.username.isEmpty { return item.username }
        if item.kind == .card, item.number.count >= 4 { return "•••• \(item.number.suffix(4))" }
        return item.primaryHost
    }
}

struct ItemEditor: View {
    var item: VaultItem
    var isNew = false
    var onSave: (VaultItem) -> Void
    var onDelete: () -> Void
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VaultItem
    @State private var websites: String
    @State private var showSecret = false
    @State private var confirmDelete = false
    @State private var showGenerator = false
    @State private var revealed = false

    init(item: VaultItem, isNew: Bool = false, onSave: @escaping (VaultItem) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: item)
        _websites = State(initialValue: item.uris.joined(separator: "\n"))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                Toggle("Favorite", isOn: $draft.favorite)
                Toggle("Ask again before showing the secret", isOn: $draft.reprompt)
                if !session.folders.isEmpty, draft.kind != .folder {
                    Picker("Folder", selection: $draft.folderID) {
                        Text("None").tag(UUID?.none)
                        ForEach(session.folders) { folder in
                            Text(folder.displayTitle).tag(Optional(folder.id))
                        }
                    }
                }
            }
            fields
            if !draft.passwordHistory.isEmpty, revealed {
                Section("Previous passwords") {
                    ForEach(draft.passwordHistory, id: \.self) { old in
                        Text(old).font(.system(.body, design: .monospaced))
                    }
                }
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
        }
        .navigationTitle(isNew ? draft.kind.label : draft.displayTitle)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).buttonStyle(.glassProminent)
            }
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
            if draft.deleted != nil {
                ToolbarItem(placement: .automatic) {
                    Button("Restore") {
                        session.restore(draft.id)
                        dismiss()
                    }
                }
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Trash. Empty Trash removes it from this vault and from iCloud.")
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorSheet { value in
                draft.password = value
            }
        }
        .id(item.id)
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .login:
            Section("Login") {
                TextField("Username", text: $draft.username)
                secretField("Password", text: $draft.password)
                TextField("Websites", text: $websites, axis: .vertical).lineLimit(2...4)
                TextField("Authentication secret or otpauth link", text: $draft.totp)
                codeLine
            }
        case .password:
            Section("Password") { secretField("Password", text: $draft.password) }
        case .note:
            EmptyView()
        case .card:
            Section("Card") {
                TextField("Name on card", text: $draft.cardholder)
                secretField("Number", text: $draft.number)
                TextField("Expiry", text: $draft.expiry)
                secretField("Security code", text: $draft.securityCode)
            }
        case .identity:
            Section("Identity") {
                TextField("First name", text: $draft.firstName)
                TextField("Last name", text: $draft.lastName)
                TextField("Email", text: $draft.email)
                TextField("Phone", text: $draft.phone)
                TextField("Address", text: $draft.address, axis: .vertical)
            }
        case .passkey:
            Section("Passkey") {
                TextField("Site", text: $draft.relyingParty)
                TextField("Username", text: $draft.username)
                LabeledContent("Sign count", value: "\(draft.signCount)")
                Text("The private key stays in the vault. Keys does not show it.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        case .wifi:
            Section("Wi-Fi") { secretField("Password", text: $draft.password) }
        case .code:
            Section("Code") {
                TextField("Secret or otpauth link", text: $draft.totp)
                codeLine
            }
        case .folder:
            EmptyView()
        }
    }

    @ViewBuilder
    private var codeLine: some View {
        if OneTimeCode.secret(from: draft.totp) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let code = OneTimeCode.code(secret: draft.totp, time: context.date) {
                    LabeledContent("Code") {
                        Button(code) { Task { if await reveal() { session.copy(code) } } }
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("\(OneTimeCode.remaining(time: context.date)) seconds").font(.reading(.footnote)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func secretField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Group {
                if showSecret && revealed {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .font(.system(.body, design: .monospaced))
            Button {
                Task {
                    if showSecret { showSecret = false; return }
                    if await reveal() { showSecret = true }
                }
            } label: {
                Image(systemName: showSecret ? "eye.slash" : "eye").symbol()
            }
            .buttonStyle(.plain)
            Button {
                Task { if await reveal() { session.copy(text.wrappedValue) } }
            } label: {
                Image(systemName: "doc.on.doc").symbol()
            }
            .buttonStyle(.plain)
            if title == "Password" {
                Button { showGenerator = true } label: {
                    Image(systemName: "wand.and.stars").symbol()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reveal() async -> Bool {
        if revealed || !draft.reprompt { revealed = true; return true }
        let context = LAContext()
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Keys needs you to confirm before showing this secret.")) ?? false
        if ok { revealed = true }
        return ok
    }

    private func save() {
        draft.uris = websites.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        onSave(draft)
        if isNew { dismiss() }
    }
}

struct GeneratorSheet: View {
    var onUse: ((String) -> Void)?
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var options = GeneratorOptions()
    @State private var words = 6
    @State private var passphrase = false
    @State private var value = PasswordGenerator.password()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(value)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Button("New password") { regenerate() }
                    Button("Copy") { session.copy(value) }
                    if onUse != nil {
                        Button("Use this password") {
                            onUse?(value)
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                Section {
                    Toggle("Passphrase", isOn: $passphrase)
                    if passphrase {
                        Stepper("\(words) words", value: $words, in: 4...12)
                    } else {
                        Stepper("\(options.length) characters", value: $options.length, in: 8...128)
                        Toggle("Uppercase", isOn: $options.upper)
                        Toggle("Lowercase", isOn: $options.lower)
                        Toggle("Digits", isOn: $options.digits)
                        Toggle("Symbols", isOn: $options.symbols)
                        Toggle("Skip lookalikes", isOn: $options.skipAmbiguous)
                    }
                }
            }
            .navigationTitle("Generator")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .onChange(of: options) { _, _ in regenerate() }
            .onChange(of: words) { _, _ in regenerate() }
            .onChange(of: passphrase) { _, _ in regenerate() }
        }
        .tint(.asteriaAccent)
    }

    private func regenerate() {
        value = passphrase ? PasswordGenerator.passphrase(count: words) : PasswordGenerator.password(options)
    }
}

struct AuditList: View {
    @Environment(VaultSession.self) private var session
    @Binding var selection: UUID?

    var body: some View {
        let findings = VaultAudit.findings(session.items)
        List(findings) { finding in
            Button {
                selection = finding.itemID
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title).font(.reading(.body, weight: .semibold))
                    Text(finding.reason).font(.reading(.subheadline)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Health")
        .overlay {
            if findings.isEmpty {
                ContentUnavailableView("Looking good", systemImage: "checkmark.shield", description: Text("No reused, short, old, or code-less logins."))
            }
        }
    }
}

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var updated = ""
    @State private var confirm = ""
    @State private var passwordMessage = ""
    @State private var importReview: ImportReview?
    @State private var importing = false
    @State private var exportFile: DataFile?
    @State private var exporting = false
    @State private var confirmCSV = false
    @State private var confirmEmpty = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Wordmark(size: 28)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                Section("Sync") {
                    LabeledContent("iCloud", value: session.syncStatus)
                    Text("Keys does not use an Asteria server. Your iCloud account stores ciphertext. The master password never leaves your devices.")
                        .font(.reading(.callout))
                        .foregroundStyle(.secondary)
                    Button("Sync now") { Task { await session.syncNow() } }
                }
                Section("AutoFill") {
                    LabeledContent("Keys in AutoFill", value: session.autofillOn ? "On" : "Off")
                    Text("Turn on Keys in Settings, under AutoFill & Passwords. Keys asks you to unlock before it fills a password, a code, or a passkey.")
                        .font(.reading(.callout))
                        .foregroundStyle(.secondary)
                }
                Section("Master password") {
                    SecureField("Current", text: $current)
                    SecureField("New", text: $updated)
                    SecureField("Confirm", text: $confirm)
                    Button("Change master password") { Task { await change() } }
                    if !passwordMessage.isEmpty {
                        Text(passwordMessage).font(.reading(.footnote)).foregroundStyle(.secondary)
                    }
                    Text("The recovery key cannot be shown again. A forgotten master password is recoverable only with that key.")
                        .font(.reading(.footnote))
                        .foregroundStyle(.secondary)
                }
                Section("Import and export") {
                    Button("Import CSV or unencrypted JSON") { importing = true }
                    Button("Export encrypted vault") { exportEncrypted() }
                    Button("Export plaintext CSV") { confirmCSV = true }
                }
                Section("On this device") {
                    Button("Lock now") {
                        session.lock()
                        dismiss()
                    }
                    Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                }
                Section("Privacy") {
                    Text("Apple Intelligence reads only the sentence you type into Capture. It never sees the vault, and it does not invent passwords.")
                    Text("Passkeys sync inside the encrypted vault, so a site you register on this iPhone is available on your Mac.")
                    Text("Asteria License 1.0")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .tint(.asteriaAccent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .json, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                session.message = "That file could not be read."
                return
            }
            do {
                let items = try parseImport(data)
                importReview = ImportReview(items: items)
            } catch {
                session.message = error.localizedDescription
            }
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
                    Button("Cancel") { importReview = nil }
                    Button("Import") {
                        session.message = session.importItems(review.items)
                        importReview = nil
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .data, defaultFilename: exportingName) { _ in
            exportFile = nil
        }
        .confirmationDialog("Export passwords as plaintext?", isPresented: $confirmCSV, titleVisibility: .visible) {
            Button("Export plaintext CSV", role: .destructive) { exportCSV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file contains passwords anyone can read.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { session.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These items are removed from this vault and from iCloud.")
        }
    }

    private var exportingName: String {
        exportFile?.filename ?? "Keys.vault"
    }

    private func change() async {
        if let problem = await session.changePassword(current: current, newPassword: updated, confirm: confirm) {
            passwordMessage = problem
        } else {
            passwordMessage = "Master password changed."
            current = ""
            updated = ""
            confirm = ""
        }
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
}

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
