import LocalAuthentication
import SwiftUI

struct ItemEditorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var isNew: Bool
    var onSave: (VaultItem) -> Void
    var onDelete: (() -> Void)?

    @State private var draft: VaultItem
    @State private var websites: String
    @State private var showSecret = false
    @State private var revealed = false
    @State private var showGenerator = false
    @State private var confirmDelete = false
    @FocusState private var focus: Bool

    init(item: VaultItem, isNew: Bool = false, onSave: @escaping (VaultItem) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: item)
        _websites = State(initialValue: item.uris.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                        .focused($focus)
                    if draft.kind != .folder, !session.folders.isEmpty {
                        Picker("Folder", selection: $draft.folderID) {
                            Text("None").tag(UUID?.none)
                            ForEach(session.folders) { folder in
                                Text(folder.displayTitle).tag(Optional(folder.id))
                            }
                        }
                    }
                    Toggle("Favorite", isOn: $draft.favorite)
                    Toggle("Ask before showing secrets", isOn: $draft.reprompt)
                }

                fields

                Section {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Notes are encrypted with the rest of the vault.")
                }

                if draft.deleted != nil {
                    Section {
                        Button("Restore from Trash", systemImage: "arrow.uturn.backward") {
                            var restored = draft
                            restored.deleted = nil
                            restored.revised = .now
                            onSave(restored)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New \(draft.kind.label)" : draft.displayTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isNew {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(!canSave)
                }
                if !isNew {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .sheet(isPresented: $showGenerator) {
                GeneratorSheet { value in
                    draft.password = value
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let onDelete {
                        onDelete()
                    } else {
                        session.delete(draft.id)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It moves to Trash. Empty Trash removes it from this vault and from iCloud.")
            }
            .onAppear {
                if isNew { focus = true }
            }
        }
        .tint(preferences.accent.color)
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.username.isEmpty
            || !draft.password.isEmpty
            || !draft.notes.isEmpty
            || !draft.cardholder.isEmpty
            || !draft.number.isEmpty
            || !draft.totp.isEmpty
            || !draft.firstName.isEmpty
            || !draft.email.isEmpty
            || !draft.relyingParty.isEmpty
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .login:
            Section("Login") {
                TextField("Username", text: $draft.username)
                secretField("Password", text: $draft.password)
                TextField("Websites, one per line", text: $websites, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Authentication secret or otpauth link", text: $draft.totp)
                codeLine
            }
        case .password:
            Section("Password") {
                secretField("Password", text: $draft.password)
            }
        case .note:
            EmptyView()
        case .card:
            Section("Card") {
                TextField("Name on card", text: $draft.cardholder)
                secretField("Number", text: $draft.number, generator: false)
                TextField("Expiry", text: $draft.expiry)
                secretField("Security code", text: $draft.securityCode, generator: false)
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
                Text("The private key stays in the encrypted vault. Keys never shows it.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
            }
        case .wifi:
            Section("Wi-Fi") {
                secretField("Password", text: $draft.password)
            }
        case .code:
            Section("Code") {
                TextField("Secret or otpauth link", text: $draft.totp)
                codeLine
            }
        case .folder:
            EmptyView()
        }
    }

    private func secretField(_ title: String, text: Binding<String>, generator: Bool = true) -> some View {
        HStack(spacing: 8) {
            Group {
                if showSecret {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .font(.system(.body, design: .monospaced))
            Button {
                Task {
                    if showSecret { showSecret = false; return }
                    if await canReveal() { showSecret = true }
                }
            } label: {
                Image(systemName: showSecret ? "eye.slash" : "eye").symbol()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(showSecret ? "Hide \(title)" : "Show \(title)")
            if generator {
                Button {
                    showGenerator = true
                } label: {
                    Image(systemName: "wand.and.stars").symbol()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Generate a password")
            }
        }
    }

    @ViewBuilder
    private var codeLine: some View {
        if OneTimeCode.secret(from: draft.totp) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let code = OneTimeCode.code(secret: draft.totp, time: context.date) {
                    LabeledContent("Code") {
                        Button {
                            session.copy(code)
                        } label: {
                            Text(code).font(.system(.body, design: .monospaced)).monospacedDigit()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy one-time code")
                    }
                    Text("\(OneTimeCode.remaining(time: context.date)) seconds")
                        .font(.reading(.footnote))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func canReveal() async -> Bool {
        guard draft.reprompt || preferences.requireAuthToReveal else { revealed = true; return true }
        if revealed { return true }
        let context = LAContext()
        context.localizedReason = "Show a secret in Keys"
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Confirm before Keys shows this secret.")) ?? false
        revealed = ok
        return ok
    }

    private func save() {
        draft.uris = websites
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(draft)
        dismiss()
    }
}
