#if DEBUG
import Foundation

/// A deterministic vault for screenshots, the App Review recording, and UI checks.
///
/// Launch with `-demo` (and usually `-no-cloud`). It never runs in a Release build and never overwrites
/// a vault it cannot open with the demo password.
@MainActor
enum DemoVault {
    static let password = "AsteriaDemo!2026"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    static var openFirst: Bool {
        ProcessInfo.processInfo.arguments.contains("-open")
            && ProcessInfo.processInfo.arguments.contains("first")
    }

    /// Opens the existing demo vault, or creates one when this device has no vault yet.
    static func load() throws -> (key: Data, items: [VaultItem])? {
        if let file = VaultDisk.read() {
            guard let key = try? VaultCrypto.unlock(password: password, header: file.header) else { return nil }
            return (key, try VaultBox.openAll(file, key: key))
        }

        let made = try VaultCrypto.makeVault(password: password)
        let items = samples()
        var file = VaultFile.empty(header: made.header)
        file.headerNeedsUpload = false
        file.records = try items.map { try VaultBox.seal($0, key: made.key) }
        try VaultDisk.write(file)
        return (made.key, items)
    }

    private static func samples() -> [VaultItem] {
        func make(_ kind: ItemKind, _ title: String, username: String = "", password: String = "",
                  site: String = "", notes: String = "", favorite: Bool = false) -> VaultItem {
            var item = VaultItem(kind: kind)
            item.title = title
            item.username = username
            item.password = password
            item.uris = site.isEmpty ? [] : [site]
            item.notes = notes
            item.favorite = favorite
            item.revised = Date(timeIntervalSince1970: 1_790_000_000 + Double(abs(title.hashValue % 10_000)))
            return item
        }

        return [
            make(.login, "GitHub", username: "ada@asteria.technology", password: "starlight-otter-88!",
                 site: "https://github.com", notes: "Work account. One-time code is in the vault.", favorite: true),
            make(.login, "Asteria Mail", username: "ada@asteria.technology", password: "cedar-harbour-31#",
                 site: "https://mail.asteria.technology", favorite: true),
            make(.login, "Figma", username: "ada", password: "figma-design-2026", site: "https://figma.com"),
            make(.card, "Asteria Visa", notes: "Travel card"),
            make(.note, "Recovery checklist", notes: "1. Keep the recovery key offline.\n2. Test a restore every quarter."),
            make(.wifi, "Studio Wi-Fi", username: "asteria-studio", password: "quiet-orbit-77"),
            make(.identity, "Ada Lovelace", notes: "Work identity"),
            make(.passkey, "Passkey demo", site: "example.com", notes: "A passkey stored on this device."),
        ]
    }
}
#endif
