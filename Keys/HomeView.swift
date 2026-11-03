import SwiftUI
import AppIntents

struct HomeView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    var onNew: (ItemKind) -> Void
    var onGenerator: () -> Void
    var onCapture: () -> Void
    var onNavigate: (VaultDestination) -> Void
    var onSettings: () -> Void

    @State private var showCoach = false
    @State private var showSiriTip = true

    private var stats: VaultStats { session.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if session.liveCount == 0 {
                    welcome
                } else {
                    securityCard
                }

                quickActions

                if !session.recents.isEmpty {
                    recent
                }

                syncCard
                intelligenceCard
                siriCard
                footer
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        #if os(iOS)
        // The Asteria wordmark is the page header; a large navigation title would repeat it.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { showSiriTip = preferences.showSiriTip }
        .onChange(of: showSiriTip) { _, visible in
            // Dismissing the tip is a real choice; remember it instead of showing it again next launch.
            if preferences.showSiriTip != visible { preferences.showSiriTip = visible }
        }
        .sheet(isPresented: $showCoach) {
            SecurityCoachView()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Wordmark(size: 28)
            Spacer()
            Button {
                onNavigate(.health)
            } label: {
                StatusPill(text: stats.grade, symbol: "checkmark.shield",
                           tint: stats.score >= 85 ? Palette.pass : (stats.score >= 60 ? Palette.gold : Palette.alert))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Security score \(stats.score) out of 100. Open Security.")
        }
    }

    private var welcome: some View {
        GlassCard(tint: Palette.sea) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Your vault is ready", systemImage: "sparkles")
                    .font(.reading(.title2, weight: .semibold))
                Text("Add a login, generate a password, or let Apple Intelligence draft one from a sentence.")
                    .font(.reading(.callout))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        onNew(.login)
                    } label: {
                        Label("Add a login", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    Button("Settings") { onSettings() }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var securityCard: some View {
        GlassCard(tint: stats.score >= 85 ? Palette.pass : Palette.gold) {
            HStack(spacing: 18) {
                ScoreRing(score: stats.score, size: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stats.grade).font(.reading(.title3, weight: .semibold))
                    Text(stats.issueCount == 0
                         ? "No reused, short, or old passwords."
                         : "\(stats.issueCount) items could be stronger.")
                        .font(.reading(.callout))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Review") { onNavigate(.health) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        Button("Ask Coach") { showCoach = true }
                            .buttonStyle(.borderless)
                            .font(.reading(.caption, weight: .medium))
                            .lineLimit(1)
                            .accessibilityLabel("Ask Apple Intelligence for a security briefing")
                            .disabled(!preferences.intelligenceEnabled || !preferences.securityCoachEnabled || !KeysIntelligence.onDeviceStatus.isReady)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quick actions", subtitle: "The things people do most")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                QuickAction(title: "New Login", subtitle: "Site, username, password", symbol: "key.fill",
                            tint: Palette.sea) { onNew(.login) }
                QuickAction(title: "Generate", subtitle: "A strong password", symbol: "wand.and.stars",
                            tint: Palette.gold) { onGenerator() }
                if preferences.captureEnabled {
                    QuickAction(title: "Capture", subtitle: "Draft from a sentence", symbol: "apple.intelligence",
                                tint: Color(light: 0x6A43B5, dark: 0xAE8CF0)) { onCapture() }
                }
                QuickAction(title: "Security", subtitle: "Review weak passwords", symbol: "checkmark.shield",
                            tint: Palette.pass) { onNavigate(.health) }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Recent", subtitle: "The last items you changed")
                Spacer()
                Button("See all") { onNavigate(.all) }
                    .font(.reading(.subheadline, weight: .medium))
                    .buttonStyle(.borderless)
            }
            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(session.recents.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item.id) {
                            ItemRowView(item: item)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .appEntityIdentifier(EntityIdentifier(for: VaultItemEntity.self, identifier: item.id.uuidString))
                        if index < session.recents.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var syncCard: some View {
        if session.demoMode {
            GlassCard {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: "sparkles", color: Palette.sea)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Demo vault").font(.reading(.headline, weight: .semibold))
                        Text("iCloud and sync are off for this run. Everything else works as it does in the shipping app.")
                            .font(.reading(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            GlassCard {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: session.syncPhase.symbol,
                             color: session.syncPhase == .failed ? Palette.alert : Palette.sea)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.syncPhase.label).font(.reading(.headline, weight: .semibold))
                        if let error = session.syncError, !error.isEmpty {
                            Text(error).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                        } else {
                            Text(session.syncMessage).font(.reading(.footnote)).foregroundStyle(.secondary)
                        }
                        if session.pendingUploads > 0 {
                            Text("\(session.pendingUploads) waiting to upload")
                                .font(.reading(.caption)).foregroundStyle(.secondary)
                        }
                        if let last = session.lastSync {
                            Text("Last sync \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.reading(.caption)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await session.syncNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise").symbol()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(session.syncPhase == .syncing)
                    .accessibilityLabel("Sync now")
                }
            }
        }
    }

    private var intelligenceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Apple Intelligence", systemImage: "apple.intelligence")
                        .font(.reading(.headline, weight: .semibold))
                    Spacer()
                    if KeysIntelligence.canUseCloud {
                        StatusPill(text: "Private Cloud Compute", symbol: "cloud", tint: Palette.sea)
                    } else if KeysIntelligence.onDeviceStatus.isReady {
                        StatusPill(text: "On device", symbol: "iphone", tint: Palette.pass)
                    }
                }
                Text(intelligenceCopy)
                    .font(.reading(.callout))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showCoach = true
                    } label: {
                        Label("Security coach", systemImage: "sparkles")
                    }
                    .buttonStyle(.glass)
                    .disabled(!preferences.intelligenceEnabled || !preferences.securityCoachEnabled || !KeysIntelligence.onDeviceStatus.isReady)
                    Button("Settings") { onSettings() }
                        .buttonStyle(.borderless)
                        .font(.reading(.subheadline, weight: .medium))
                }
                Text("Never sees a password, username, site name, or note.")
                    .font(.reading(.caption2))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var intelligenceCopy: String {
        if !preferences.intelligenceEnabled {
            return "Apple Intelligence is off. Turn it on in Settings to draft logins and get a security coach."
        }
        let status = KeysIntelligence.onDeviceStatus
        if !status.isReady { return status.explanation }
        if KeysIntelligence.canUseCloud {
            return "Capture and smart search run on this device. The security coach can use Apple's Private Cloud Compute for deeper reasoning, with counts only."
        }
        return "Capture and smart search run on this device. The security coach explains your findings without ever seeing a secret."
    }

    @ViewBuilder
    private var siriCard: some View {
        #if os(iOS)
        if preferences.showSiriTip {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Ask Siri", subtitle: "Keys is built for the new Siri")
                SiriTipView(intent: SearchVaultIntent(), isVisible: $showSiriTip)
            }
        }
        #endif
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keys keeps your vault encrypted on this device and stores only ciphertext in your own iCloud.")
                .font(.reading(.caption))
                .foregroundStyle(.secondary)
            Text("Asteria Keys 2.0")
                .font(.reading(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}
