import SwiftUI

struct SecurityCoachView: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var advice: SecurityAdvice?
    @State private var working = false
    @State private var message = ""
    @State private var usedCloud = false

    private var stats: VaultStats { session.stats }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if working {
                        GlassCard {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Reading your security findings…")
                                    .font(.reading(.callout))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let advice {
                        GlassCard(tint: Palette.sea) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(advice.headline).font(.reading(.title3, weight: .semibold))
                                Text(advice.encouragement).font(.reading(.callout)).foregroundStyle(.secondary)
                            }
                        }
                        if !advice.priorities.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("What to do next").font(.reading(.headline, weight: .semibold))
                                    ForEach(Array(advice.priorities.enumerated()), id: \.offset) { index, item in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text("\(index + 1)")
                                                .font(.reading(.caption, weight: .bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 22, height: 22)
                                                .background(Palette.sea, in: .circle)
                                            Text(item).font(.reading(.body))
                                        }
                                    }
                                }
                            }
                        }
                    } else if !message.isEmpty {
                        GlassCard {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.reading(.callout))
                                .foregroundStyle(Palette.alert)
                        }
                    }

                    if !stats.redactedSummary.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("What the coach sees").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                                Text(stats.redactedSummary)
                                    .font(.reading(.footnote))
                                    .foregroundStyle(.secondary)
                                Text("Counts only. Never a password, username, site name, note, or card number.")
                                    .font(.reading(.caption2))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await generate() }
                        } label: {
                            Label(advice == nil ? "Get a briefing" : "Regenerate", systemImage: "sparkles")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(working || !preferences.intelligenceEnabled || !preferences.securityCoachEnabled
                                  || !KeysIntelligence.onDeviceStatus.isReady)
                        if KeysIntelligence.privateCloudEntitled {
                            StatusPill(text: KeysIntelligence.privateCloudQuota, symbol: "cloud", tint: Palette.sea)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Security Coach")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generate() }
        }
        .tint(preferences.accent.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "apple.intelligence")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.sea)
                Text("Apple Intelligence").font(.reading(.headline, weight: .semibold))
                Spacer()
                StatusPill(text: usedCloud ? "Private Cloud Compute" : "On device",
                           symbol: usedCloud ? "cloud" : "iphone",
                           tint: usedCloud ? Palette.sea : Palette.pass)
            }
            Text("A short, practical plan for the findings in your vault. It never sees a secret.")
                .font(.reading(.callout))
                .foregroundStyle(.secondary)
        }
    }

    private func generate() async {
        guard preferences.securityCoachEnabled else {
            message = "The security coach is off. Turn it on in Settings, under Apple Intelligence."
            return
        }
        guard preferences.intelligenceEnabled, KeysIntelligence.onDeviceStatus.isReady else {
            message = KeysIntelligence.onDeviceStatus.explanation
            return
        }
        working = true
        message = ""
        defer { working = false }
        usedCloud = preferences.usePrivateCloudCompute && KeysIntelligence.canUseCloud
        do {
            let briefing = try await SecurityCoach().advice(stats: stats, useCloud: usedCloud)
            advice = briefing.advice
            usedCloud = briefing.usedCloud
        } catch {
            message = KeysIntelligence.message(for: error)
        }
    }
}

struct SmartSearchSheet: View {
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    var onResult: (SmartQuery) -> Void

    @State private var text = ""
    @State private var working = false
    @State private var message = ""
    @FocusState private var focus: Bool

    private let examples = [
        "weak passwords I haven't changed in a year",
        "logins without a one-time code",
        "favorites that are cards",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Find with Apple Intelligence", systemImage: "sparkles")
                                .font(.reading(.headline, weight: .semibold))
                            Text("Describe what you are looking for. Keys turns it into filters, then searches locally.")
                                .font(.reading(.callout))
                                .foregroundStyle(.secondary)
                            TextField("For example: old passwords in logins", text: $text, axis: .vertical)
                                .font(.reading(.body))
                                .lineLimit(2...4)
                                .focused($focus)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                            Button {
                                Task { await find() }
                            } label: {
                                Label("Find", systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Try").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(examples, id: \.self) { example in
                            Button {
                                text = example
                                Task { await find() }
                            } label: {
                                HStack {
                                    Text(example).font(.reading(.subheadline))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").symbol().font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !message.isEmpty {
                        Text(message).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                    }
                    Text("Runs on this device. The words you type never go to a server.")
                        .font(.reading(.caption2))
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Apple Intelligence Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focus = true }
        }
        .tint(preferences.accent.color)
    }

    private func find() async {
        guard preferences.intelligenceEnabled, preferences.smartSearchEnabled else {
            message = "Turn on Apple Intelligence search in Settings."
            return
        }
        guard KeysIntelligence.onDeviceStatus.isReady else {
            message = KeysIntelligence.onDeviceStatus.explanation
            return
        }
        working = true
        message = ""
        defer { working = false }
        do {
            let query = try await SmartSearch.parse(text)
            onResult(query)
            dismiss()
        } catch {
            message = KeysIntelligence.message(for: error)
        }
    }
}

/// The visual Siri AI result for a vault health check. Counts only; never an item name or a secret.
struct VaultHealthSnippet: View {
    var stats: VaultStats?

    var body: some View {
        HStack(spacing: 14) {
            if let stats {
                ScoreRing(score: stats.score, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stats.grade).font(.reading(.headline, weight: .semibold))
                    Text(stats.issueCount == 0
                         ? "No reused, short, or old passwords."
                         : "\(stats.issueCount) items could be stronger.")
                        .font(.reading(.footnote))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "lock.fill").symbol().font(.title2).foregroundStyle(Palette.sea)
                Text("Unlock Keys to check the vault.").font(.reading(.callout))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 340)
    }
}
