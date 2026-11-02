// Shared views for Keys 2.0: the pieces every screen uses so the app reads as one design.
import SwiftUI

// MARK: - Navigation

enum VaultDestination: Hashable, Identifiable {
    case home
    case all
    case favorites
    case health
    case trash
    case kind(ItemKind)
    case folder(UUID)
    case settings

    var id: String {
        switch self {
        case .home: "home"
        case .all: "all"
        case .favorites: "favorites"
        case .health: "health"
        case .trash: "trash"
        case .kind(let kind): "kind-\(kind.rawValue)"
        case .folder(let id): "folder-\(id.uuidString)"
        case .settings: "settings"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .all: "All Items"
        case .favorites: "Favorites"
        case .health: "Security"
        case .trash: "Trash"
        case .kind(let kind): kind.label
        case .folder: "Folder"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .all: "key"
        case .favorites: "star"
        case .health: "checkmark.shield"
        case .trash: "trash"
        case .kind(let kind): kind.symbol
        case .folder: "folder"
        case .settings: "gearshape"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, security, sync, autofill, intelligence, siri, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .security: "Security"
        case .sync: "iCloud Sync"
        case .autofill: "AutoFill"
        case .intelligence: "Apple Intelligence"
        case .siri: "Siri & Spotlight"
        case .data: "Data"
        case .about: "About"
        }
    }

    var caption: String {
        switch self {
        case .general: "Appearance, accent, and glass"
        case .security: "Face ID, auto-lock, and the master password"
        case .sync: "Devices, status, and diagnostics"
        case .autofill: "Passwords, codes, and passkeys in other apps"
        case .intelligence: "On-device and Private Cloud Compute"
        case .siri: "Shortcuts, Spotlight, and Handoff"
        case .data: "Import, export, and erase"
        case .about: "Version, privacy, and licences"
        }
    }

    var symbol: String {
        switch self {
        case .general: "paintpalette"
        case .security: "lock.shield"
        case .sync: "arrow.triangle.2.circlepath.icloud"
        case .autofill: "rectangle.and.pencil.and.ellipsis"
        case .intelligence: "apple.intelligence"
        case .siri: "waveform"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: Palette.sea
        case .security: Palette.gold
        case .sync: Color(light: 0x1D5FA8, dark: 0x5EA8F2)
        case .autofill: Color(light: 0x2F7A3E, dark: 0x6FCB82)
        case .intelligence: Color(light: 0x6A43B5, dark: 0xAE8CF0)
        case .siri: Color(light: 0xAD2F62, dark: 0xF27BAA)
        case .data: Color(light: 0x4A5560, dark: 0xA7B2BD)
        case .about: Palette.emphasis
        }
    }
}

// MARK: - Small pieces

struct FilterChip: View {
    var title: String
    var symbol: String?
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).symbol().font(.caption)
            }
            Text(title).font(.reading(.subheadline, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.14), in: .capsule)
        .contentShape(.capsule)
    }
}

struct ScoreRing: View {
    var score: Int
    var size: CGFloat = 96

    private var tint: Color {
        switch score {
        case 85...: Palette.pass
        case 60..<85: Palette.gold
        default: Palette.alert
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.09)
            Circle()
                .trim(from: 0, to: max(0.01, CGFloat(score) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.reading(.title2, weight: .bold)).monospacedDigit()
                Text("of 100").font(.reading(.caption2)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security score \(score) out of 100")
    }
}

struct QuickAction: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    IconTile(symbol: symbol, color: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.reading(.subheadline, weight: .semibold))
                        Text(subtitle).font(.reading(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

struct ToastView: View {
    var text: String
    var symbol: String = "checkmark.circle.fill"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.reading(.subheadline, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .accessibilityAddTraits(.isStaticText)
    }
}

struct ItemRowView: View {
    var item: VaultItem

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.kind.symbol, color: item.kind.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).font(.reading(.body, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.reading(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.favorite {
                Image(systemName: "star.fill").symbol().font(.caption).foregroundStyle(Palette.gold)
                    .accessibilityLabel("Favorite")
            }
            if OneTimeCode.secret(from: item.totp) != nil {
                Image(systemName: "number.square").symbol().font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Has a one-time code")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if !item.username.isEmpty { return item.username }
        if item.kind == .card, item.number.count >= 4 { return "•••• \(item.number.suffix(4))" }
        if item.kind == .note { return String(item.notes.prefix(60)) }
        return item.primaryHost
    }
}

struct SettingsRow: View {
    var pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: pane.symbol, color: pane.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.reading(.body))
                Text(pane.caption).font(.reading(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct FieldLine: View {
    var title: String
    var value: String
    var symbol: String?
    var monospaced = false
    var onCopy: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).symbol().foregroundStyle(.secondary).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.reading(.caption)).foregroundStyle(.secondary)
                Text(value.isEmpty ? "—" : value)
                    .font(monospaced ? .system(.body, design: .monospaced) : .reading(.body))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let onCopy, !value.isEmpty {
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc").symbol()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(title)")
            }
        }
        .padding(.vertical, 3)
    }
}

struct ContentHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.reading(.largeTitle, weight: .bold))
            Text(subtitle).font(.reading(.subheadline)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
