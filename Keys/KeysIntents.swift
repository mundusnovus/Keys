import AppIntents
import Foundation

struct VaultEntryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Item")
    static let defaultQuery = VaultEntryQuery()

    var id: String
    var title: String
    var domain: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(domain)")
    }
}

struct VaultEntryQuery: EntityQuery {
    func entities(for identifiers: [VaultEntryEntity.ID]) async throws -> [VaultEntryEntity] {
        []
    }

    func suggestedEntities() async throws -> [VaultEntryEntity] {
        await MainActor.run {
            guard let session = KeysRuntime.session, session.phase == .unlocked else { return [] }
            return session.visible(filter: .all, query: "").prefix(8).map { item in
                VaultEntryEntity(id: item.id.uuidString, title: item.displayTitle, domain: item.primaryHost)
            }
        }
    }
}

struct OpenKeysIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Keys"
    static let description = IntentDescription("Opens Keys.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct SearchVaultIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Keys"
    static let description = IntentDescription("Finds an item by name. Keys never speaks a password.")
    static let openAppWhenRun = true

    @Parameter(title: "Words", requestValueDialog: IntentDialog("What should Keys look for?"))
    var words: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Keys for \(\.$words)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let titles = await MainActor.run {
            KeysRuntime.session?.searchTitles(words) ?? []
        }
        guard await MainActor.run(body: { KeysRuntime.session?.phase == .unlocked }) else {
            return .result(dialog: "Unlock Keys to search.")
        }
        if titles.isEmpty {
            return .result(dialog: "Nothing in Keys matches that.")
        }
        return .result(dialog: "\(titles.joined(separator: ", "))")
    }
}

struct GeneratePasswordIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate a password"
    static let description = IntentDescription("Copies a new password. Keys does not speak it.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let password = PasswordGenerator.password()
        await MainActor.run { Clipboard.copySecret(password) }
        return .result(dialog: "A password is on the clipboard. It will be cleared shortly.")
    }
}

struct LockKeysIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Keys"
    static let description = IntentDescription("Locks the vault.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { KeysRuntime.session?.lock() }
        return .result(dialog: "Keys is locked.")
    }
}

struct KeysShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenKeysIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "Open", systemImageName: "key")
        AppShortcut(intent: SearchVaultIntent(), phrases: ["Search \(.applicationName)"], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: GeneratePasswordIntent(), phrases: ["Generate a password in \(.applicationName)"], shortTitle: "Generate", systemImageName: "wand.and.stars")
        AppShortcut(intent: LockKeysIntent(), phrases: ["Lock \(.applicationName)"], shortTitle: "Lock", systemImageName: "lock")
    }
}
