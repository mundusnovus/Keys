// Siri AI, App Intents, Spotlight, and Handoff for Keys 2.0.
//
// The shapes follow the 27 SDK: an AppEntity that is also an IndexedEntity, a query that reads the one vault on
// the main actor, the system.open and system.searchInApp schemas so Apple Intelligence can find an item, and App
// Shortcuts whose phrases interpolate only the app name or an entity. No intent ever speaks a secret.
import AppIntents
import CoreSpotlight
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Entity

struct VaultItemEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Vault Item",
        numericFormat: "\(placeholder: .int) items"
    )
    static let defaultQuery = VaultItemQuery()

    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Site") var domain: String
    @Property(title: "Kind") var kind: String

    init(item: VaultItem) {
        id = item.id.uuidString
        title = item.displayTitle
        domain = item.primaryHost
        kind = item.kind.label
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind) · \(domain)",
            image: .init(systemName: "key.fill")
        )
    }

    /// Titles and sites only. Passwords, usernames, notes, codes, and card numbers are never indexed.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = "\(kind) in Asteria Keys"
        attributes.keywords = [kind, domain, "Keys", "password"]
        return attributes
    }
}

struct VaultItemQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [VaultItemEntity.ID]) async throws -> [VaultItemEntity] {
        await MainActor.run {
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return [] }
            let wanted = Set(identifiers)
            return session.items
                .filter { $0.deleted == nil && wanted.contains($0.id.uuidString) }
                .map(VaultItemEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [VaultItemEntity] {
        await MainActor.run {
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return [] }
            return session.visible(filter: .all, query: string).prefix(20).map(VaultItemEntity.init)
        }
    }

    func suggestedEntities() async throws -> [VaultItemEntity] {
        await MainActor.run {
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return [] }
            return session.items
                .filter { $0.deleted == nil && $0.kind != .folder }
                .sorted { $0.revised > $1.revised }
                .prefix(12)
                .map(VaultItemEntity.init)
        }
    }

    func reindexEntities(for identifiers: [VaultItemEntity.ID],
                        indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let allowed = await MainActor.run { KeysRuntime.session?.preferences.shareWithSiri ?? false }
        let entities = allowed ? await allEntities() : []
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    private func allEntities() async -> [VaultItemEntity] {
        await MainActor.run {
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return [] }
            return session.items
                .filter { $0.deleted == nil && $0.kind != .folder }
                .map(VaultItemEntity.init)
        }
    }
}

// MARK: - Spotlight

@MainActor
enum SpotlightIndex {
    /// Index titles and sites only, and only while the person allows Siri to see them. Turning it off deletes
    /// every indexed entity, not just future ones.
    static func reindex(_ items: [VaultItem], allowed: Bool) async {
        guard allowed else {
            await removeAll()
            return
        }
        let entities = items
            .filter { $0.deleted == nil && $0.kind != .folder }
            .map(VaultItemEntity.init)
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            // Spotlight is best-effort; a failure must never block a vault save.
        }
    }

    static func removeAll() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}

// MARK: - Intents

@AppIntent(schema: .system.open)
struct OpenItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open an Item in Keys"
    static let description = IntentDescription("Opens a login, note, or card in Asteria Keys.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Item", requestValueDialog: "Which item should Keys open?")
    var target: VaultItemEntity

    func perform() async throws -> some IntentResult {
        let id = UUID(uuidString: target.id)
        await MainActor.run {
            KeysRuntime.session?.openItemID = id
        }
        return .result()
    }
}

/// Siri AI can compose the shape of a login. It never speaks or generates a secret: the app makes the
/// password on the device and opens the editor so the person reviews it before saving.
struct ComposeLoginIntent: AppIntent {
    static let title: LocalizedStringResource = "Compose a Login"
    static let description = IntentDescription("Prepares a login in Asteria Keys and opens it for review. Keys generates the password on this device.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Name", requestValueDialog: "What should I call the login?")
    var name: String

    @Parameter(title: "Website")
    var site: String?

    @Parameter(title: "Username")
    var username: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = ComposeRequest(kind: .login, title: name, site: site ?? "", username: username ?? "")
        await MainActor.run {
            KeysRuntime.session?.composeRequest = request
        }
        return .result(dialog: "I prepared \(name) in Keys. Review it and choose Save.")
    }
}

/// Siri AI can hand a sentence to the on-device composer. The sentence stays on this device because it
/// may contain a secret; the model turns it into fields and the person confirms them.
struct CaptureLoginIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft a Login from a Sentence"
    static let description = IntentDescription("Turns a sentence into a login draft in Asteria Keys, on this device.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Description", requestValueDialog: "Describe the login.")
    var sentence: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            KeysRuntime.session?.captureRequest = sentence
        }
        return .result(dialog: "I opened Capture in Keys. Check the fields before saving.")
    }
}

@AppIntent(schema: .system.searchInApp)
struct SearchVaultIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Find in Keys"
    static let description = IntentDescription("Searches the names, usernames, and sites in your vault. Keys never speaks a password.")
    static var searchScopes: [StringSearchScope] { [.general] }

    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult {
        let term = criteria.term
        await MainActor.run {
            KeysRuntime.session?.searchRequest = term
        }
        return .result()
    }
}

struct OpenKeysIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Keys"
    static let description = IntentDescription("Opens Asteria Keys.")
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct GeneratePasswordIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate a Password"
    static let description = IntentDescription("Copies a new strong password. Keys does not speak it.")
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let password = PasswordGenerator.password()
        await MainActor.run {
            let session = KeysRuntime.session
            let seconds = session?.preferences.clipboardClear.rawValue ?? 60
            Clipboard.copySecret(password, clearAfter: TimeInterval(seconds))
        }
        return .result(dialog: "A new password is on the clipboard. It will be cleared shortly.")
    }
}

struct CopyPasswordIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy a Password"
    static let description = IntentDescription("Copies the password for an item. Requires an unlocked vault.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Item", requestValueDialog: "Which password should Keys copy?")
    var target: VaultItemEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let found = await MainActor.run { () -> VaultItem? in
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return nil }
            return session.item(UUID(uuidString: target.id))
        }
        guard let found, !found.password.isEmpty else {
            return .result(dialog: "Unlock Keys, then try again.")
        }
        await MainActor.run {
            let session = KeysRuntime.session
            let seconds = session?.preferences.clipboardClear.rawValue ?? 60
            Clipboard.copySecret(found.password, clearAfter: TimeInterval(seconds))
        }
        return .result(dialog: "The password for \(found.displayTitle) is on the clipboard.")
    }
}

struct LockKeysIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Keys"
    static let description = IntentDescription("Locks the vault.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { KeysRuntime.session?.lock() }
        return .result(dialog: "Keys is locked.")
    }
}

struct VaultHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Vault Health"
    static let description = IntentDescription("Says how many security issues the vault has. It never lists a password.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let state = await MainActor.run { () -> (Bool, VaultStats) in
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return (false, VaultStats()) }
            return (true, session.stats)
        }
        guard state.0 else {
            return .result(dialog: "Unlock Keys to check the vault.", view: VaultHealthSnippet(stats: nil))
        }
        let stats = state.1
        if stats.issueCount == 0 {
            return .result(dialog: "Your vault looks good. Keys found no reused, short, or old passwords.",
                           view: VaultHealthSnippet(stats: stats))
        }
        return .result(dialog: "Keys found \(stats.issueCount) items to review. Open Keys to see them.",
                       view: VaultHealthSnippet(stats: stats))
    }
}

// MARK: - App Shortcuts

struct KeysShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKeysIntent(),
            phrases: ["Open \(.applicationName)", "Open my \(.applicationName) vault"],
            shortTitle: "Open Keys",
            systemImageName: "key.fill"
        )
        AppShortcut(
            intent: SearchVaultIntent(),
            phrases: ["Find in \(.applicationName)", "Search \(.applicationName)"],
            shortTitle: "Find in Keys",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenItemIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)", "Show \(\.$target) in \(.applicationName)"],
            shortTitle: "Open an Item",
            systemImageName: "key.horizontal"
        )
        AppShortcut(
            intent: ComposeLoginIntent(),
            phrases: ["Compose a login in \(.applicationName)", "Make a login in \(.applicationName)"],
            shortTitle: "Compose a Login",
            systemImageName: "rectangle.and.pencil.and.ellipsis"
        )
        AppShortcut(
            intent: CaptureLoginIntent(),
            phrases: ["Draft a login in \(.applicationName)", "Capture a login in \(.applicationName)"],
            shortTitle: "Draft a Login",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: GeneratePasswordIntent(),
            phrases: ["Generate a password in \(.applicationName)"],
            shortTitle: "Generate a Password",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: LockKeysIntent(),
            phrases: ["Lock \(.applicationName)"],
            shortTitle: "Lock Keys",
            systemImageName: "lock.fill"
        )
    }
}
