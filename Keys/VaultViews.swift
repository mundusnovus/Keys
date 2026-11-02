// The lock, setup, recovery, and mismatch screens. Every one is a single obvious path: one primary button,
// one explanation, and no hidden toolbar action.
import LocalAuthentication
import SwiftUI

struct VaultRoot: View {
    @Environment(VaultSession.self) private var session
    @Environment(KeysPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                VStack(spacing: 14) {
                    Wordmark(size: 30)
                    ProgressView().controlSize(.large)
                    Text("Opening Keys").font(.reading(.callout)).foregroundStyle(.secondary)
                }
            case .setup:
                SetupView()
            case .recovery:
                RecoveryView()
            case .locked:
                LockView()
            case .mismatch:
                MismatchView()
            case .unlocked:
                MainView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.reading(.body))
        .tint(preferences.accent.color)
        .background {
            LinearGradient(colors: [Palette.sea.opacity(0.10), Palette.gold.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await session.noteActive() }
            case .background:
                session.noteBackground()
            default:
                break
            }
        }
        .onChange(of: session.suggestBiometrics) { _, suggest in
            if suggest {
                session.suggestBiometrics = false
                showBiometrics = true
            }
        }
        .sheet(isPresented: $showBiometrics) {
            BiometricsPrompt()
        }
    }

    @State private var showBiometrics = false
}

// MARK: - Lock

struct LockView: View {
    @Environment(VaultSession.self) private var session
    @State private var revealPassword = false
    @State private var showRecovery = false
    @State private var triedBiometrics = false
    @FocusState private var focus: Bool

    var body: some View {
        @Bindable var session = session
        return ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                VStack(spacing: 8) {
                    Wordmark(size: 40)
                    Text("Your vault, only yours.").font(.reading(.subheadline)).foregroundStyle(.secondary)
                }
                GlassCard {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Master password").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Group {
                                    if revealPassword {
                                        TextField("Master password", text: $session.password)
                                    } else {
                                        SecureField("Master password", text: $session.password)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.reading(.body))
                                .focused($focus)
                                .onSubmit { Task { await session.unlock() } }
                                .accessibilityLabel("Master password")
                                Button {
                                    revealPassword.toggle()
                                } label: {
                                    Image(systemName: revealPassword ? "eye.slash" : "eye").symbol()
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(revealPassword ? "Hide master password" : "Show master password")
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                        }

                        Button {
                            Task { await session.unlock() }
                        } label: {
                            Label("Unlock", systemImage: "lock.open")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(session.working || session.password.isEmpty)

                        if session.biometricsEnabled && session.biometricsAvailable {
                            Button {
                                Task { await session.unlockBiometric() }
                            } label: {
                                Label(FaceIDCopy.unlock, systemImage: FaceIDCopy.symbol)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }

                        if !session.message.isEmpty {
                            Text(session.message)
                                .font(.reading(.footnote))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        Divider().opacity(0.4)

                        Button("Use a recovery key") { showRecovery = true }
                            .font(.reading(.subheadline, weight: .medium))
                    }
                }
                .frame(maxWidth: 430)

                Text("Keys cannot reset your master password. Your recovery key is the only backup.")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            focus = true
            guard !triedBiometrics, session.biometricsEnabled, session.biometricsAvailable else { return }
            triedBiometrics = true
            Task { await session.unlockBiometric() }
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryUnlockView()
        }
    }
}

enum FaceIDCopy {
    static var unlock: String {
        #if os(macOS)
        "Unlock with Touch ID"
        #else
        "Unlock with Face ID"
        #endif
    }

    static var enable: String {
        #if os(macOS)
        "Turn on Touch ID"
        #else
        "Turn on Face ID"
        #endif
    }

    static var symbol: String {
        #if os(macOS)
        "touchid"
        #else
        "faceid"
        #endif
    }

    static var name: String {
        #if os(macOS)
        "Touch ID"
        #else
        "Face ID"
        #endif
    }
}

// MARK: - Setup

struct SetupView: View {
    @Environment(VaultSession.self) private var session
    @State private var confirm = ""
    @State private var reveal = false
    @FocusState private var focus: Bool

    var body: some View {
        @Bindable var session = session
        return ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                VStack(spacing: 8) {
                    Wordmark(size: 40)
                    Text("A vault that never leaves your devices unencrypted.")
                        .font(.reading(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Create your vault").font(.reading(.title2, weight: .semibold))
                        Text("Choose a master password. It wraps the key to everything in Keys, and only you know it.")
                            .font(.reading(.callout))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Master password").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            HStack {
                                Group {
                                    if reveal {
                                        TextField("At least 12 characters", text: $session.password)
                                    } else {
                                        SecureField("At least 12 characters", text: $session.password)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .focused($focus)
                                .accessibilityLabel("Master password")
                                Button {
                                    reveal.toggle()
                                } label: {
                                    Image(systemName: reveal ? "eye.slash" : "eye").symbol()
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(reveal ? "Hide master password" : "Show master password")
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                        }

                        StrengthMeter(password: session.password)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Confirm").font(.reading(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            SecureField("Type it again", text: $confirm)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                                .accessibilityLabel("Confirm master password")
                        }

                        Button {
                            Task { await session.create(password: session.password, confirm: confirm) }
                        } label: {
                            Label("Create vault", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(session.working || session.password.count < 12 || confirm.isEmpty)

                        if !session.message.isEmpty {
                            Text(session.message).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                        }
                    }
                }
                .frame(maxWidth: 460)

                Label("A recovery key comes next. It is shown once.", systemImage: "key.horizontal")
                    .font(.reading(.footnote))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focus = true }
    }
}

private struct StrengthMeter: View {
    var password: String

    private var score: Int {
        guard !password.isEmpty else { return 0 }
        var value = min(4, password.count / 5)
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { value += 1 }
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { value += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { value += 1 }
        if password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil { value += 1 }
        return min(4, value)
    }

    private var label: String {
        switch score {
        case 0: "Start typing"
        case 1: "Weak"
        case 2: "Fair"
        case 3: "Good"
        default: "Strong"
        }
    }

    private var tint: Color {
        switch score {
        case 0, 1: Palette.alert
        case 2: Palette.gold
        default: Palette.pass
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < score ? tint : Color.secondary.opacity(0.16))
                        .frame(height: 5)
                }
            }
            Text(label).font(.reading(.caption, weight: .medium)).foregroundStyle(tint).frame(width: 68, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(label)")
    }
}

// MARK: - Recovery

struct RecoveryView: View {
    @Environment(VaultSession.self) private var session
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                Wordmark(size: 34)
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Save your recovery key", systemImage: "key.horizontal.fill")
                            .font(.reading(.title2, weight: .semibold))
                        Text("Keys shows this once. Without it, a forgotten master password cannot be recovered. Anyone with this key can open your vault, so keep it somewhere only you can reach.")
                            .font(.reading(.callout))
                            .foregroundStyle(.secondary)
                        Text(session.recovery)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.cream.opacity(0.28), in: .rect(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.gold.opacity(0.3))
                            }
                            .accessibilityLabel("Recovery key")
                        HStack {
                            Button {
                                session.copy(session.recovery)
                            } label: {
                                Label("Copy key", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.glass)
                            Spacer()
                            Button {
                                saved.toggle()
                            } label: {
                                Label(saved ? "Saved" : "I saved it", systemImage: saved ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.borderless)
                            .font(.reading(.subheadline, weight: .medium))
                        }
                        Button {
                            session.acknowledgeRecovery()
                        } label: {
                            Label("Continue", systemImage: "arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!saved)
                    }
                }
                .frame(maxWidth: 480)
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct RecoveryUnlockView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recovery key", text: $key, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The groups of four characters, exactly as Keys showed them.")
                }
                if !session.recoveryMessage.isEmpty {
                    Section {
                        Text(session.recoveryMessage).foregroundStyle(Palette.alert)
                    }
                }
                Section {
                    Button {
                        Task {
                            await session.unlockRecovery(key)
                            if session.phase == .unlocked { dismiss() }
                        }
                    } label: {
                        Label("Unlock with recovery key", systemImage: "key.horizontal")
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.working)
                }
            }
            .navigationTitle("Recovery Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.accentColor)
        .frame(minWidth: 380, minHeight: 320)
    }
}

// MARK: - Mismatch

struct MismatchView: View {
    @Environment(VaultSession.self) private var session
    @State private var confirmReplace = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                Wordmark(size: 34)
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Two vaults", systemImage: "exclamationmark.triangle")
                            .font(.reading(.title2, weight: .semibold))
                        Text("iCloud has a different Keys vault than this device. Keys will not merge two master passwords.")
                            .font(.reading(.callout))
                            .foregroundStyle(.secondary)
                        Button {
                            session.keepLocalVault()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Keep this device's vault", systemImage: "iphone")
                                    .font(.reading(.body, weight: .semibold))
                                Text("Sync pauses. This device keeps its own vault.")
                                    .font(.reading(.caption)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                        Button(role: .destructive) {
                            confirmReplace = true
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Open the iCloud vault", systemImage: "icloud")
                                    .font(.reading(.body, weight: .semibold))
                                Text("Removes the vault that exists only on this device.")
                                    .font(.reading(.caption)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: 480)
                Spacer(minLength: 24)
            }
            .padding(24)
        }
        .confirmationDialog("Open the iCloud vault?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace this device's vault", role: .destructive) {
                Task { await session.useICloudVault() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items stored only on this device will be removed.")
        }
    }
}

// MARK: - Biometrics prompt

struct BiometricsPrompt: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: FaceIDCopy.symbol)
                    .font(.system(size: 54, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.sea)
                VStack(spacing: 8) {
                    Text(FaceIDCopy.enable).font(.reading(.title2, weight: .semibold))
                    Text("Unlock Keys without typing your master password. The key is kept in the keychain, behind \(FaceIDCopy.name), and never leaves this device.")
                        .font(.reading(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !session.biometricsMessage.isEmpty {
                    Text(session.biometricsMessage).font(.reading(.footnote)).foregroundStyle(Palette.alert)
                }
                VStack(spacing: 10) {
                    Button {
                        if session.enableBiometrics() { dismiss() }
                    } label: {
                        Label(FaceIDCopy.enable, systemImage: FaceIDCopy.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button("Not now") { dismiss() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
            .padding(26)
            .frame(maxWidth: 430)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Palette.sea)
    }
}

// MARK: - Password reset after recovery

struct PasswordResetView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New master password", text: $password)
                    SecureField("Confirm new master password", text: $confirm)
                    StrengthMeter(password: password)
                } footer: {
                    Text("Use at least 12 characters. The recovery key you just used stays valid.")
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(Palette.alert) }
                }
                Section {
                    Button {
                        Task {
                            if let problem = await session.setNewPassword(password, confirm: confirm) {
                                message = problem
                            } else {
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Set master password", systemImage: "checkmark.shield")
                    }
                    .disabled(password.count < 12 || confirm.isEmpty)
                }
            }
            .navigationTitle("New Master Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .tint(.accentColor)
        .frame(minWidth: 400, minHeight: 360)
    }
}
