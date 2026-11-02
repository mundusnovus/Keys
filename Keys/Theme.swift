// Asteria's design system for Keys 2.0.
//
// SF Pro for everything a person reads, Asteria Pixel for the word "Asteria" only, built-in SF Symbols in
// hierarchical rendering, and Liquid Glass for chrome. Multiplatform: no UIKit or AppKit type leaks out.
import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Colour

enum Palette {
    static let sea = Color(hex: 0x1C8C9E)
    static let seaBright = Color(hex: 0x3BB3C3)
    static let seaDeep = Color(hex: 0x116674)
    static let gold = Color(hex: 0xE9B04B)
    static let goldDeep = Color(hex: 0xA8761A)
    static let night = Color(hex: 0x0C1A2B)
    static let cream = Color(hex: 0xFBF1DC)
    static let alert = Color(hex: 0xC4432D)
    static let pass = Color(hex: 0x4CAF7A)
    /// Gold for small emphasis. Gold deep on light surfaces keeps 4.5:1 contrast.
    static let emphasis = Color(light: 0xA8761A, dark: 0xE9B04B)
}

/// Accents a person can choose. Each has a darker light-mode and a brighter dark-mode value so tinted text
/// keeps 4.5:1 contrast. Stored in iCloud key-value storage, so every device matches.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case sea, lagoon, gold, coral, rose, violet, forest, graphite

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    private var hexes: (UInt32, UInt32) {
        switch self {
        case .sea: (0x116674, 0x3BB3C3)
        case .lagoon: (0x1D5FA8, 0x5EA8F2)
        case .gold: (0x8A5F10, 0xE9B04B)
        case .coral: (0xB23A26, 0xF07F69)
        case .rose: (0xAD2F62, 0xF27BAA)
        case .violet: (0x6A43B5, 0xAE8CF0)
        case .forest: (0x2F7A3E, 0x6FCB82)
        case .graphite: (0x4A5560, 0xA7B2BD)
        }
    }

    var color: Color { Color(light: hexes.0, dark: hexes.1) }
    var symbol: String {
        switch self {
        case .sea: "water.waves"
        case .lagoon: "drop"
        case .gold: "sun.max"
        case .coral: "flame"
        case .rose: "heart"
        case .violet: "sparkles"
        case .forest: "leaf"
        case .graphite: "circle.grid.2x2"
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    /// A colour that changes with light and dark appearance, on both platforms.
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
        }
        let l = components(light), d = components(dark)
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    // Compatibility with the extension target, which shares this file's older names.
    static let asteriaAccent = Palette.sea
    static let asteriaDeep = Palette.seaDeep
    static let asteriaGold = Palette.gold
    static let asteriaCream = Palette.cream
}

extension ItemKind {
    /// One colour per kind so a list can be read at a glance.
    var tint: Color {
        switch self {
        case .login: Palette.sea
        case .password: Color(light: 0xA8761A, dark: 0xE9B04B)
        case .note: Color(light: 0x6A43B5, dark: 0xAE8CF0)
        case .card: Color(light: 0x1D5FA8, dark: 0x5EA8F2)
        case .identity: Color(light: 0x2F7A3E, dark: 0x6FCB82)
        case .passkey: Color(light: 0xAD2F62, dark: 0xF27BAA)
        case .wifi: Color(light: 0x4A5560, dark: 0xA7B2BD)
        case .code: Color(light: 0xB23A26, dark: 0xF07F69)
        case .folder: Palette.sea
        }
    }
}

// MARK: - Type

/// Registers Asteria Pixel. SF Pro is the system font and is never bundled.
///
/// RULE: look the font up by its PostScript name, `AsteriaPixel-Regular`. "Asteria Pixel" is the family name,
/// and a lookup by family can fail silently and fall back to the system font.
enum BrandFont {
    static let postScriptName = "AsteriaPixel-Regular"

    /// True when Asteria Pixel can be drawn. Touch it once in `App.init`.
    static let isRegistered: Bool = {
        if CTFontCreateWithName(postScriptName as CFString, 12, nil).postScriptName == postScriptName { return true }
        guard let url = Bundle.main.url(forResource: "AsteriaPixel-Regular", withExtension: "ttf") else { return false }
        // Returns false when the font is already registered. That is fine; the check below is what counts.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCreateWithName(postScriptName as CFString, 12, nil).postScriptName == postScriptName
    }()
}

private extension CTFont {
    var postScriptName: String { CTFontCopyPostScriptName(self) as String }
}

extension Font {
    /// Asteria Pixel, for the word "Asteria" and nothing else. Fixed size on purpose: it is a logo.
    static func asteria(_ size: CGFloat) -> Font {
        BrandFont.isRegistered ? .custom(BrandFont.postScriptName, fixedSize: size) : .system(size: size, weight: .semibold)
    }

    /// SF Pro, the system font, for everything a person reads. Text styles follow Dynamic Type.
    static func reading(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

extension Image {
    /// An SF Symbol drawn the way the system draws them. Call this BEFORE `.foregroundStyle`.
    func symbol() -> some View {
        symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Brand and surfaces

/// "Asteria" in Asteria Pixel and the product word in SF Pro: the pattern every Asteria app uses for its name.
struct Wordmark: View {
    var product = "Keys"
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            Text("Asteria").font(.asteria(size))
            Text(product).font(.system(size: size * 0.82, weight: .semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asteria \(product)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A frosted card, the Food and Mood surface. Use for grouped content that floats over the page, not every row.
struct GlassCard<Content: View>: View {
    var tint: Color?
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: 22))
    }
}

/// A coloured rounded tile behind an SF Symbol. The list's visual anchor.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .symbol()
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: .rect(cornerRadius: size * 0.3))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(color.opacity(0.16), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// Small status word with a symbol: "Synced", "Paused", "On".
struct StatusPill: View {
    var text: String
    var symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.reading(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.reading(.headline, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.reading(.footnote)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An icon-only control still needs a name. This makes the label explicit and keeps it out of the artwork.
struct IconButtonLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .accessibilityLabel(title)
    }
}
