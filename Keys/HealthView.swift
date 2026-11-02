import SwiftUI

struct HealthView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    var onNew: (ItemKind) -> Void

    @State private var showCoach = false

    private var stats: VaultStats { session.stats }
    private var findings: [AuditFinding] { session.findings }

    var body: some View {
        List {
            Section {
                GlassCard(tint: stats.score >= 85 ? Palette.pass : Palette.gold) {
                    HStack(spacing: 18) {
                        ScoreRing(score: stats.score, size: 100)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stats.grade).font(.reading(.title2, weight: .semibold))
                            Text(summary).font(.reading(.callout)).foregroundStyle(.secondary)
                            Button {
                                showCoach = true
                            } label: {
                                Label("Explain with Apple Intelligence", systemImage: "sparkles")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(!preferences.intelligenceEnabled || !KeysIntelligence.onDeviceStatus.isReady)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            ForEach(AuditKind.allCases, id: \.self) { kind in
                let rows = findings.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { finding in
                            NavigationLink(value: finding.itemID) {
                                HStack(spacing: 12) {
                                    IconTile(symbol: kind.symbol, color: tint(for: kind))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.title).font(.reading(.body, weight: .semibold))
                                        Text(finding.reason).font(.reading(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text(title(for: kind))
                    } footer: {
                        Text(footer(for: kind)).font(.reading(.footnote))
                    }
                }
            }

            if findings.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Looking good", systemImage: "checkmark.shield")
                    } description: {
                        Text("No reused, short, or old passwords. Keys checks names and ages; it never sends a password anywhere.")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Security")
        .sheet(isPresented: $showCoach) {
            SecurityCoachView()
        }
    }

    private var summary: String {
        if findings.isEmpty { return "No issues found. Keep adding codes to new logins." }
        return "\(stats.issueCount) items to review. Start with reused passwords."
    }

    private func title(for kind: AuditKind) -> String {
        switch kind {
        case .reused: "Reused passwords"
        case .short: "Short passwords"
        case .old: "Older than a year"
        case .missingCode: "No one-time code"
        }
    }

    private func footer(for kind: AuditKind) -> String {
        switch kind {
        case .reused: "One leak can open several accounts. Give each its own password."
        case .short: "Twelve characters or more makes guessing impractical."
        case .old: "A password that has not changed in a year is worth replacing."
        case .missingCode: "A one-time code keeps a stolen password from being enough."
        }
    }

    private func tint(for kind: AuditKind) -> Color {
        switch kind {
        case .reused: Palette.alert
        case .short: Palette.gold
        case .old: Color(light: 0x1D5FA8, dark: 0x5EA8F2)
        case .missingCode: Color(light: 0x6A43B5, dark: 0xAE8CF0)
        }
    }
}
