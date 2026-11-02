import SwiftUI

struct ContentView: View {
    let session: VaultSession
    let preferences: KeysPreferences

    var body: some View {
        VaultRoot()
            .environment(session)
            .environment(preferences)
            .onContinueUserActivity(KeysActivity.type) { activity in
                guard let raw = activity.userInfo?["id"] as? String,
                      let id = UUID(uuidString: raw) else { return }
                session.openItemID = id
            }
            .onOpenURL { url in
                guard url.scheme == "keys",
                      let id = UUID(uuidString: url.lastPathComponent) else { return }
                session.openItemID = id
            }
    }
}
