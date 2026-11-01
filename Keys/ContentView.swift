import SwiftUI

struct ContentView: View {
    @State private var session: VaultSession

    init() {
        _session = State(initialValue: VaultSession())
    }

    var body: some View {
        let _ = KeysRuntime.attach(session)
        VaultRoot()
            .environment(session)
            .task { await session.start() }
    }
}
