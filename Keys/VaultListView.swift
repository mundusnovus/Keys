import SwiftUI
import AppIntents
#if os(iOS)
import UIKit
#endif

struct VaultListView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    var destination: VaultDestination
    var onNew: (ItemKind) -> Void
    var onGenerator: () -> Void
    var onNavigate: (VaultDestination) -> Void

    @State private var query = ""
    @State private var sort: SortOrder = .name
    @State private var smartQuery: SmartQuery?
    @State private var showSmartSearch = false
    @State private var pendingDelete: UUID?
    @State private var confirmEmpty = false

    private enum SortOrder: String, CaseIterable, Identifiable {
        case name, recent, created
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .recent: "Recently changed"
            case .created: "Recently added"
            }
        }
        var symbol: String {
            switch self {
            case .name: "textformat.abc"
            case .recent: "clock.arrow.circlepath"
            case .created: "calendar.badge.plus"
            }
        }
    }

    private var filter: VaultFilter {
        switch destination {
        case .all: .all
        case .favorites: .favorites
        case .trash: .trash
        case .health: .health
        case .kind(let kind): .kind(kind)
        case .folder(let id): .folder(id)
        default: .all
        }
    }

    private var title: String {
        if case .folder(let id) = destination {
            return session.folders.first { $0.id == id }?.displayTitle ?? "Folder"
        }
        return destination.title
    }

    private var items: [VaultItem] {
        var result = session.visible(filter: filter, query: query)
        if let smartQuery { result = smartQuery.items(from: result) }
        switch sort {
        case .name:
            result.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .recent:
            result.sort { $0.revised > $1.revised }
        case .created:
            result.sort { $0.created > $1.created }
        }
        return result
    }

    var body: some View {
        List {
            if destination == .all {
                chips
            }
            if let smartQuery {
                Section {
                    HStack(spacing: 8) {
                        Label("Apple Intelligence: \(smartQuery.summary)", systemImage: "sparkles")
                            .font(.reading(.footnote, weight: .medium))
                            .foregroundStyle(Palette.sea)
                        Spacer()
                        Button {
                            self.smartQuery = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").symbol()
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear Apple Intelligence filter")
                    }
                }
            }
            if items.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(items) { item in
                        NavigationLink(value: item.id) {
                            ItemRowView(item: item)
                        }
                        .appEntityIdentifier(EntityIdentifier(for: VaultItemEntity.self, identifier: item.id.uuidString))
                        .contextMenu {
                            Button(item.favorite ? "Remove Favorite" : "Favorite", systemImage: item.favorite ? "star.slash" : "star") {
                                session.toggleFavorite(item.id)
                            }
                            Button("Duplicate", systemImage: "doc.on.doc") { session.duplicate(item.id) }
                            if item.deleted == nil {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item.id }
                            } else {
                                Button("Restore", systemImage: "arrow.uturn.backward") { session.restore(item.id) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if item.deleted == nil {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item.id }
                            } else {
                                Button("Restore", systemImage: "arrow.uturn.backward") { session.restore(item.id) }
                                    .tint(Palette.pass)
                            }
                        }
                    }
                } footer: {
                    Text(footerCopy)
                        .font(.reading(.footnote))
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $query, prompt: "Names, usernames, sites")
        .navigationTitle(title)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { compactActions }
        .sheet(isPresented: $showSmartSearch) {
            SmartSearchSheet { result in
                smartQuery = result
            }
        }
        .onChange(of: session.searchRequest) { _, words in
            consumeSearch(words)
        }
        .task {
            consumeSearch(session.searchRequest)
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

    private func consumeSearch(_ words: String?) {
        guard let words else { return }
        query = words
        session.searchRequest = nil
    }

    private var footerCopy: String {
        if destination == .trash { return "Items wait here until you empty Trash. Emptying removes them from iCloud too." }
        if destination == .favorites { return "Starred items stay here on every device." }
        return "\(items.count) items. Keys searches names, usernames, and sites, never passwords."
    }

    private var chips: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", symbol: "square.grid.2x2", destination: .all)
                    chip("Favorites", symbol: "star", destination: .favorites)
                    ForEach([ItemKind.login, .password, .note, .card, .identity, .passkey, .wifi, .code]) { kind in
                        chip(kind.label, symbol: kind.symbol, destination: .kind(kind))
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private func chip(_ title: String, symbol: String, destination: VaultDestination) -> some View {
        Button {
            onNavigate(destination)
        } label: {
            FilterChip(title: title, symbol: symbol, isSelected: self.destination == destination)
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ItemKind.allCases.filter { $0 != .passkey && $0 != .folder }) { kind in
                    Button(kind.label, systemImage: kind.symbol) { onNew(kind) }
                }
                Divider()
                Button("Generate Password", systemImage: "wand.and.stars") { onGenerator() }
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("New item")
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { order in
                        Label(order.label, systemImage: order.symbol).tag(order)
                    }
                }
                if preferences.intelligenceEnabled && preferences.smartSearchEnabled && KeysIntelligence.onDeviceStatus.isReady {
                    Divider()
                    Button("Find with Apple Intelligence", systemImage: "sparkles") { showSmartSearch = true }
                }
            } label: {
                Label("Sort and find", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort and find")
        }
        if destination == .trash {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    confirmEmpty = true
                } label: {
                    Label("Empty Trash", systemImage: "trash")
                }
                .disabled(items.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var compactActions: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        onNew(.login)
                    } label: {
                        Label("New", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        onGenerator()
                    } label: {
                        Label("Generate", systemImage: "wand.and.stars")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Generate a password")
                    if preferences.intelligenceEnabled {
                        Button {
                            showSmartSearch = true
                        } label: {
                            Label("Find with Apple Intelligence", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Find with Apple Intelligence")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: destination == .trash ? "trash" : "key")
                .symbol()
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(destination == .trash ? "Trash is empty" : "Nothing here yet")
                .font(.reading(.title3, weight: .semibold))
            Text(emptyCopy)
                .font(.reading(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if destination != .trash {
                Button {
                    onNew(.login)
                } label: {
                    Label("Add a login", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyCopy: String {
        switch destination {
        case .trash: "Deleted items wait here until you empty Trash."
        case .favorites: "Star an item and it appears here on every device."
        case .health: "No reused, short, or old passwords."
        default: "Add a login, a note, or a card. Or ask Apple Intelligence to draft one."
        }
    }
}
