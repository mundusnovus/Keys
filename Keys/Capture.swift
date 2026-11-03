import Foundation
import FoundationModels
import SwiftUI

@Generable
struct CaptureDraft {
    @Guide(description: "Short name of the login. No password.")
    var title: String
    @Guide(description: "Host name of the site, or empty.")
    var site: String
    @Guide(description: "Username, or empty.")
    var username: String
    @Guide(description: "A note with no secret, or empty.")
    var note: String
}

@MainActor
enum CaptureService {
    static var available: Bool {
        KeysIntelligence.isEnabled
    }

    /// On the device only. A sentence a person types can contain a secret, so it never goes to a server.
    static func draft(from sentence: String) async throws -> CaptureDraft {
        let session = LanguageModelSession(instructions: CaptureCopy.instructions)
        let response = try await session.respond(to: sentence, generating: CaptureDraft.self)
        return response.content
    }
}

struct CaptureSheet: View {
    var onSave: (VaultItem) -> Void
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Bool

    @State private var sentence: String
    @State private var draft = CaptureDraft(title: "", site: "", username: "", note: "")
    @State private var password = ""
    @State private var reviewing = false
    @State private var working = false
    @State private var message = ""

    init(initialSentence: String = "", onSave: @escaping (VaultItem) -> Void) {
        self.onSave = onSave
        _sentence = State(initialValue: initialSentence)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !preferences.captureEnabled {
                        GlassCard {
                            Label("Capture is off", systemImage: "apple.intelligence")
                                .font(.reading(.headline, weight: .semibold))
                            Text("Turn on Capture from a sentence in Settings to draft a login here. You can still add one yourself.")
                                .font(.reading(.callout))
                                .foregroundStyle(.secondary)
                        }
                    } else if !CaptureService.available {
                        GlassCard {
                            Label("Apple Intelligence is off", systemImage: "apple.intelligence")
                                .font(.reading(.headline, weight: .semibold))
                            Text("Turn on Apple Intelligence in Settings to draft a login from a sentence. You can still add one yourself.")
                                .font(.reading(.callout))
                                .foregroundStyle(.secondary)
                        }
                    } else if !reviewing {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Describe the login", systemImage: "apple.intelligence")
                                    .font(.reading(.headline, weight: .semibold))
                                TextField("For example: my work email at mail.example.com, username ada", text: $sentence, axis: .vertical)
                                    .font(.reading(.body))
                                    .lineLimit(3...6)
                                    .focused($focus)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                Text("Leave the password out. Capture runs on this device and never sees your vault.")
                                    .font(.reading(.footnote))
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task { await generate() }
                                } label: {
                                    Label("Draft with Apple Intelligence", systemImage: "sparkles")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                                .disabled(sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                            }
                        }
                    } else {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Review before saving").font(.reading(.headline, weight: .semibold))
                                Text("Apple Intelligence suggested these fields. Check them, then add the password yourself.")
                                    .font(.reading(.callout))
                                    .foregroundStyle(.secondary)
                                TextField("Title", text: $draft.title)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                TextField("Website", text: $draft.site)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                TextField("Username", text: $draft.username)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                SecureField("Password", text: $password)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                TextField("Note", text: $draft.note, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(2...5)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                Button {
                                    save()
                                } label: {
                                    Label("Save login", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.isEmpty)
                                Button("Start over") {
                                    reviewing = false
                                    message = ""
                                }
                                .font(.reading(.subheadline))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if !message.isEmpty {
                        Text(message).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Capture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focus = true }
            .task {
                // A sentence handed over by Siri AI is already here: draft it once, without another tap.
                if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !reviewing {
                    await generate()
                }
            }
        }
        .tint(preferences.accent.color)
    }

    private func generate() async {
        guard preferences.captureEnabled else {
            message = "Capture is off. Turn it on in Settings, under Apple Intelligence."
            return
        }
        guard CaptureService.available else {
            message = KeysIntelligence.onDeviceStatus.explanation
            return
        }
        working = true
        message = ""
        defer { working = false }
        do {
            draft = try await CaptureService.draft(from: sentence)
            reviewing = true
        } catch {
            message = KeysIntelligence.message(for: error)
        }
    }

    private func save() {
        var item = VaultItem(kind: .login)
        item.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        item.notes = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        item.password = password
        let site = draft.site.trimmingCharacters(in: .whitespacesAndNewlines)
        if !site.isEmpty { item.uris = [site] }
        if item.title.isEmpty { item.title = item.primaryHost }
        onSave(item)
        dismiss()
    }
}
