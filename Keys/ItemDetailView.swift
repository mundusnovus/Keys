import AppIntents
import LocalAuthentication
import SwiftUI

enum KeysActivity {
    static let type = "technology.asteria.keys.item"
}

struct ItemDetailView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    var itemID: UUID

    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var revealed = false
    @State private var toast: String?

    private var item: VaultItem? { session.item(itemID) }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                ContentUnavailableView("Item not found", systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted on another device."))
            }
        }
        .navigationTitle(item?.displayTitle ?? "Item")
        #if os(iOS)
        // The hero repeats the name at a readable size; a large navigation title would duplicate it.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let item {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .accessibilityLabel("Edit item")
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button(item.favorite ? "Remove Favorite" : "Favorite",
                               systemImage: item.favorite ? "star.slash" : "star") {
                            session.toggleFavorite(item.id)
                        }
                        Button("Duplicate", systemImage: "doc.on.doc") { session.duplicate(item.id) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("More actions")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let item {
                ItemEditorView(item: item) { session.save($0) }
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                session.delete(itemID)
                session.openItemID = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Trash. Empty Trash removes it from this vault and from iCloud.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(text: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
    }

    @ViewBuilder
    private func content(_ item: VaultItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(item)
                actions(item)
                if OneTimeCode.secret(from: item.totp) != nil {
                    codeCard(item)
                }
                fields(item)
                if item.deleted != nil {
                    deletedCard
                }
                metadata(item)
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .userActivity(KeysActivity.type, isActive: item.deleted == nil) { activity in
            activity.title = item.displayTitle
            activity.isEligibleForHandoff = true
            activity.appEntityIdentifier = EntityIdentifier(for: VaultItemEntity.self, identifier: item.id.uuidString)
            activity.userInfo = ["id": item.id.uuidString]
        }
        // Gives Siri AI the "this item" onscreen context without exposing any field.
        .appEntityIdentifier(EntityIdentifier(for: VaultItemEntity.self, identifier: item.id.uuidString))
    }

    private func hero(_ item: VaultItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: item.kind.symbol, color: item.kind.tint, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.reading(.title, weight: .bold))
                Text(subtitle(item)).font(.reading(.subheadline)).foregroundStyle(.secondary)
                if item.kind == .login, !item.uris.isEmpty {
                    Text(item.primaryHost).font(.reading(.caption)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                session.toggleFavorite(item.id)
            } label: {
                Image(systemName: item.favorite ? "star.fill" : "star")
                    .symbol()
                    .font(.title3)
                    .foregroundStyle(item.favorite ? Palette.gold : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.favorite ? "Remove favorite" : "Add to favorites")
        }
    }

    private func subtitle(_ item: VaultItem) -> String {
        switch item.kind {
        case .login, .password, .wifi: item.username.isEmpty ? item.kind.label : item.username
        case .card: item.cardholder.isEmpty ? "Card" : item.cardholder
        case .identity: "\(item.firstName) \(item.lastName)".trimmingCharacters(in: .whitespaces).isEmpty
            ? "Identity" : "\(item.firstName) \(item.lastName)"
        case .note: "Secure note"
        case .passkey: item.relyingParty.isEmpty ? "Passkey" : item.relyingParty
        case .code: "One-time code"
        case .folder: "Folder"
        }
    }

    private func actions(_ item: VaultItem) -> some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if !item.password.isEmpty {
                    Button {
                        Task { await copySecret(item.password, label: "Password copied") }
                    } label: {
                        Label("Copy Password", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                HStack(spacing: 10) {
                    if !item.username.isEmpty {
                        Button {
                            session.copy(item.username)
                            show("Username copied")
                        } label: {
                            Label("Username", systemImage: "person")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Copy username")
                    }
                    if let url = siteURL(item) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open Site", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .controlSize(.large)
        }
    }

    private func codeCard(_ item: VaultItem) -> some View {
        GlassCard(tint: Palette.sea) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = OneTimeCode.code(secret: item.totp, time: context.date)
                let remaining = OneTimeCode.remaining(time: context.date)
                HStack(spacing: 14) {
                    IconTile(symbol: "number.square", color: Palette.sea, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One-time code").font(.reading(.caption)).foregroundStyle(.secondary)
                        Text(code ?? "—")
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .monospacedDigit()
                            .textSelection(.enabled)
                        Text("\(remaining) seconds").font(.reading(.caption2)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let code {
                        Button {
                            session.copy(code)
                            show("Code copied")
                        } label: {
                            Image(systemName: "doc.on.doc").symbol()
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Copy one-time code")
                    }
                    ProgressView(value: Double(remaining), total: 30)
                        .progressViewStyle(.circular)
                        .frame(width: 30, height: 30)
                        .tint(Palette.sea)
                }
            }
        }
    }

    @ViewBuilder
    private func fields(_ item: VaultItem) -> some View {
        switch item.kind {
        case .login, .password:
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    if !item.username.isEmpty {
                        FieldLine(title: "Username", value: item.username, symbol: "person", onCopy: {
                            session.copy(item.username)
                            show("Username copied")
                        })
                    }
                    if !item.password.isEmpty {
                        secretLine(item.password)
                    }
                    ForEach(Array(item.uris.enumerated()), id: \.offset) { _, uri in
                        FieldLine(title: "Website", value: uri, symbol: "globe", onCopy: {
                            session.copy(uri)
                            show("Website copied")
                        })
                    }
                }
            }
        case .card:
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLine(title: "Name on card", value: item.cardholder, symbol: "person")
                    secretLine(item.number, title: "Card number")
                    FieldLine(title: "Expiry", value: item.expiry, symbol: "calendar")
                    secretLine(item.securityCode, title: "Security code")
                }
            }
        case .identity:
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLine(title: "Name", value: "\(item.firstName) \(item.lastName)".trimmingCharacters(in: .whitespaces),
                              symbol: "person")
                    FieldLine(title: "Email", value: item.email, symbol: "envelope", onCopy: {
                        session.copy(item.email); show("Email copied")
                    })
                    FieldLine(title: "Phone", value: item.phone, symbol: "phone", onCopy: {
                        session.copy(item.phone); show("Phone copied")
                    })
                    FieldLine(title: "Address", value: item.address, symbol: "house")
                }
            }
        case .wifi:
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    secretLine(item.password, title: "Wi-Fi password")
                }
            }
        case .passkey:
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLine(title: "Site", value: item.relyingParty, symbol: "globe")
                    FieldLine(title: "Username", value: item.username, symbol: "person")
                    FieldLine(title: "Sign count", value: "\(item.signCount)", symbol: "number")
                    Text("The private key stays in the encrypted vault. Keys never shows it and never sends it anywhere.")
                        .font(.reading(.footnote))
                        .foregroundStyle(.secondary)
                }
            }
        case .code:
            EmptyView()
        case .note, .folder:
            EmptyView()
        }

        if !item.notes.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    Text(item.notes).font(.reading(.body)).textSelection(.enabled)
                }
            }
        }
    }

    private func secretLine(_ value: String, title: String = "Password") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.reading(.caption)).foregroundStyle(.secondary)
                Text(revealed ? value : "••••••••••••")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                Task { await toggleReveal() }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").symbol()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
            Button {
                Task { await copySecret(value, label: "\(title) copied") }
            } label: {
                Image(systemName: "doc.on.doc").symbol()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(title.lowercased())")
        }
    }

    private var deletedCard: some View {
        GlassCard(tint: Palette.alert) {
            HStack {
                Label("This item is in Trash", systemImage: "trash")
                    .font(.reading(.body, weight: .semibold))
                Spacer()
                Button("Restore") {
                    session.restore(itemID)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func metadata(_ item: VaultItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                FieldLine(title: "Created", value: item.created.formatted(date: .abbreviated, time: .shortened), symbol: "calendar")
                FieldLine(title: "Changed", value: item.revised.formatted(date: .abbreviated, time: .shortened), symbol: "clock")
                if let folderID = item.folderID,
                   let folder = session.folders.first(where: { $0.id == folderID }) {
                    FieldLine(title: "Folder", value: folder.displayTitle, symbol: "folder")
                }
                if !item.passwordHistory.isEmpty && revealed {
                    Divider()
                    Text("Previous passwords").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(item.passwordHistory.enumerated()), id: \.offset) { _, old in
                        Text(old).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func siteURL(_ item: VaultItem) -> URL? {
        guard let first = item.uris.first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }

    private func toggleReveal() async {
        if revealed {
            revealed = false
            return
        }
        guard item?.reprompt == true || preferences.requireAuthToReveal else {
            revealed = true
            return
        }
        let context = LAContext()
        context.localizedReason = "Show this secret"
        context.localizedFallbackTitle = "Cancel"
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Confirm before Keys shows this secret.")) ?? false
        if ok { revealed = true }
    }

    private func copySecret(_ value: String, label: String) async {
        if item?.reprompt == true || preferences.requireAuthToReveal {
            guard revealed else {
                await toggleReveal()
                guard revealed else { return }
                session.copy(value)
                show(label)
                return
            }
        }
        session.copy(value)
        show(label)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == text { withAnimation { toast = nil } }
        }
    }
}
