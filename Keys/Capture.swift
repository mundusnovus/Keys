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

enum CaptureService {
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func draft(from sentence: String) async throws -> CaptureDraft {
        let session = LanguageModelSession(instructions: CaptureCopy.instructions)
        let response = try await session.respond(to: sentence, generating: CaptureDraft.self)
        return response.content
    }
}

struct CaptureSheet: View {
    var onSave: (VaultItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sentence = ""
    @State private var draft = CaptureDraft(title: "", site: "", username: "", note: "")
    @State private var password = ""
    @State private var reviewing = false
    @State private var working = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                if !CaptureService.available {
                    Section {
                        Text("Apple Intelligence is off. You can still add an item yourself.")
                            .font(.reading(.body))
                    }
                } else if !reviewing {
                    Section {
                        TextField("Describe the login. Leave the password out.", text: $sentence, axis: .vertical)
                            .font(.reading(.body))
                            .lineLimit(3...6)
                    } footer: {
                        Text("This stays on your device. The model never sees the vault.")
                            .font(.reading(.footnote))
                    }
                } else {
                    Section("Review") {
                        TextField("Title", text: $draft.title)
                        TextField("Website", text: $draft.site)
                        TextField("Username", text: $draft.username)
                        SecureField("Password", text: $password)
                        TextField("Note", text: $draft.note, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.reading(.footnote)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Capture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if reviewing {
                        Button("Save", action: save)
                            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.isEmpty)
                    } else {
                        Button("Draft") { Task { await generate() } }
                            .disabled(!CaptureService.available || sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                }
            }
        }
        .tint(.asteriaAccent)
    }

    private func generate() async {
        working = true
        message = ""
        defer { working = false }
        do {
            draft = try await CaptureService.draft(from: sentence)
            reviewing = true
        } catch {
            message = "Apple Intelligence could not draft that. You can add the item yourself."
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
