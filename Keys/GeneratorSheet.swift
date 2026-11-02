import SwiftUI

struct GeneratorSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var onUse: ((String) -> Void)?

    @State private var options = GeneratorOptions()
    @State private var words = 6
    @State private var passphrase = false
    @State private var value = PasswordGenerator.password()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A new password").font(.reading(.headline, weight: .semibold))
                            Text(value)
                                .font(.system(.title3, design: .monospaced, weight: .medium))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                .accessibilityLabel("Generated password")
                            HStack(spacing: 10) {
                                Button {
                                    regenerate()
                                } label: {
                                    Label("New", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.glass)
                                Button {
                                    session.copy(value)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.glass)
                                if let onUse {
                                    Button {
                                        onUse(value)
                                        dismiss()
                                    } label: {
                                        Label("Use", systemImage: "checkmark")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.glassProminent)
                                }
                            }
                            .controlSize(.large)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Passphrase", isOn: $passphrase)
                            if passphrase {
                                Stepper("\(words) words", value: $words, in: 4...12)
                                Text("Words are easier to type on a phone and still strong at this length.")
                                    .font(.reading(.footnote))
                                    .foregroundStyle(.secondary)
                            } else {
                                Stepper("\(options.length) characters", value: $options.length, in: 12...128)
                                Toggle("Uppercase", isOn: $options.upper)
                                Toggle("Lowercase", isOn: $options.lower)
                                Toggle("Digits", isOn: $options.digits)
                                Toggle("Symbols", isOn: $options.symbols)
                                Toggle("Skip lookalikes", isOn: $options.skipAmbiguous)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Generator")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: options) { _, _ in regenerate() }
            .onChange(of: words) { _, _ in regenerate() }
            .onChange(of: passphrase) { _, _ in regenerate() }
        }
        .tint(.accentColor)
    }

    private func regenerate() {
        value = passphrase ? PasswordGenerator.passphrase(count: words) : PasswordGenerator.password(options)
    }
}
