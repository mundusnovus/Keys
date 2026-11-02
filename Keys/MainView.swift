// The unlocked shell: a visible sidebar of destinations, a navigation stack for the detail, and one obvious
// place for every action. No control is reachable only by knowing a hidden gesture or toolbar glyph.
import SwiftUI

struct MainView: View {
    @Environment(VaultSession.self) private var session

    @State private var destination: VaultDestination = .home
    @State private var path = NavigationPath()
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSettings = false
    @State private var settingsPane: SettingsPane = .general
    @State private var newKind: ItemKind?
    @State private var showGenerator = false
    @State private var showCapture = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(
                destination: $destination,
                onSettings: { settingsPane = .general; showSettings = true },
                onLock: { session.lock() }
            )
            .navigationSplitViewColumnWidth(min: 224, ideal: 244, max: 290)
        } detail: {
            NavigationStack(path: $path) {
                DestinationView(
                    destination: destination,
                    onNew: { newKind = $0 },
                    onGenerator: { showGenerator = true },
                    onCapture: { showCapture = true },
                    onNavigate: { destination = $0 },
                    onSettings: { settingsPane = .general; showSettings = true }
                )
                .navigationDestination(for: UUID.self) { id in
                    ItemDetailView(itemID: id)
                }
            }
        }
        .onChange(of: destination) { _, _ in
            preferredColumn = .detail
            path = NavigationPath()
        }
        .onChange(of: session.openItemID) { _, id in
            guard let id else { return }
            session.openItemID = nil
            destination = .all
            preferredColumn = .detail
            Task { @MainActor in
                // Let the destination change settle before pushing, so its onChange does not clear the path.
                try? await Task.sleep(for: .milliseconds(80))
                path = NavigationPath()
                path.append(id)
            }
        }
        .onChange(of: session.searchRequest) { _, words in
            guard words != nil else { return }
            destination = .all
            preferredColumn = .detail
        }
        .onChange(of: session.newItemRequest) { _, kind in
            guard let kind else { return }
            newKind = kind
            session.newItemRequest = nil
        }
        .onChange(of: session.needsPasswordReset) { _, needs in
            if needs { showReset = true }
        }
        .sheet(item: $newKind) { kind in
            ItemEditorView(item: VaultItem(kind: kind), isNew: true) { item in
                session.save(item)
                destination = .all
                preferredColumn = .detail
                path = NavigationPath()
                path.append(item.id)
            }
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorSheet()
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet { item in
                session.save(item)
                destination = .all
                preferredColumn = .detail
                path = NavigationPath()
                path.append(item.id)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(initialPane: settingsPane)
        }
        .sheet(isPresented: $showReset) {
            PasswordResetView()
        }
        .task {
            if session.needsPasswordReset { showReset = true }
            if let kind = session.newItemRequest {
                newKind = kind
                session.newItemRequest = nil
            }
            if let id = session.openItemID {
                session.openItemID = nil
                destination = .all
                preferredColumn = .detail
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    path = NavigationPath()
                    path.append(id)
                }
            } else if session.searchRequest != nil {
                destination = .all
                preferredColumn = .detail
            }
        }
    }

    @State private var showReset = false
}

struct SidebarView: View {
    @Environment(VaultSession.self) private var session
    @Binding var destination: VaultDestination
    var onSettings: () -> Void
    var onLock: () -> Void

    var body: some View {
        List(selection: selection) {
            Section {
                HStack {
                    Wordmark(size: 24)
                    Spacer()
                    Button {
                        onLock()
                    } label: {
                        Image(systemName: "lock.fill").symbol()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Lock vault")
                }
                .padding(.vertical, 4)
            }

            Section("Vault") {
                destinationRow(.home, count: nil)
                destinationRow(.all, count: session.liveCount)
                destinationRow(.favorites, count: session.favoriteCount)
                destinationRow(.health, count: session.stats.issueCount)
                destinationRow(.trash, count: session.trashCount)
            }

            Section("Categories") {
                ForEach(ItemKind.allCases.filter { $0 != .folder }) { kind in
                    destinationRow(.kind(kind), count: session.count(for: .kind(kind)), symbol: kind.symbol, tint: kind.tint)
                }
            }

            if !session.folders.isEmpty {
                Section("Folders") {
                    ForEach(session.folders) { folder in
                        destinationRow(.folder(folder.id), count: session.count(for: .folder(folder.id)),
                                       title: folder.displayTitle, symbol: "folder", tint: Palette.sea)
                    }
                }
            }

            Section {
                Button(action: onSettings) {
                    Label {
                        Text("Settings").font(.reading(.body))
                    } icon: {
                        Image(systemName: "gearshape").symbol()
                    }
                }
                .buttonStyle(.plain)
                syncFooter
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Keys")
    }

    private var selection: Binding<VaultDestination?> {
        Binding {
            destination
        } set: { next in
            if let next { destination = next }
        }
    }

    @ViewBuilder
    private func destinationRow(_ value: VaultDestination, count: Int?, title: String? = nil,
                                symbol: String? = nil, tint: Color? = nil) -> some View {
        Label {
            HStack {
                Text(title ?? value.title).font(.reading(.body))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.reading(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol ?? value.symbol)
                .symbol()
                .foregroundStyle(tint ?? Color.accentColor)
        }
        .tag(value)
    }

    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.syncPhase.symbol)
                    .symbol()
                    .foregroundStyle(session.syncPhase == .failed ? Palette.alert : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.syncPhase.label).font(.reading(.caption, weight: .medium))
                    if let last = session.lastSync {
                        Text(last, style: .relative).font(.reading(.caption2)).foregroundStyle(.secondary)
                    } else {
                        Text(session.syncMessage).font(.reading(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Sync now") {
                    Task { await session.syncNow() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(session.syncPhase == .syncing)
                if session.syncPhase == .paused {
                    Button("Resume") { session.resumeSync() }
                        .buttonStyle(.borderless)
                        .font(.reading(.caption, weight: .medium))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DestinationView: View {
    @Environment(VaultSession.self) private var session
    var destination: VaultDestination
    var onNew: (ItemKind) -> Void
    var onGenerator: () -> Void
    var onCapture: () -> Void
    var onNavigate: (VaultDestination) -> Void
    var onSettings: () -> Void

    var body: some View {
        switch destination {
        case .home:
            HomeView(onNew: onNew, onGenerator: onGenerator, onCapture: onCapture,
                     onNavigate: onNavigate, onSettings: onSettings)
        case .health:
            HealthView(onNew: onNew)
        case .settings:
            SettingsView(initialPane: .general)
        default:
            VaultListView(destination: destination, onNew: onNew, onGenerator: onGenerator,
                          onNavigate: onNavigate)
        }
    }
}
