import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    static let asteriaAccent = Color(hex: 0xFF0058)
    static let asteriaDeep = Color(hex: 0x9E0036)
    static let asteriaGold = Color(hex: 0xE9B04B)
    static let asteriaCream = Color(hex: 0xFBF1DC)
}

extension Font {
    /// Asteria Pixel, for the word Asteria. Reading text stays in SF Pro.
    static func asteria(_ size: CGFloat) -> Font {
        Fonts.registered ? .custom(Fonts.name, size: size) : .system(size: size, weight: .semibold)
    }

    /// SF Pro, the system font.
    static func reading(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

enum Fonts {
    static let name = "Asteria Pixel"

    static let registered: Bool = {
        if existing() { return true }
        guard let url = Bundle.main.url(forResource: "AsteriaPixel-Regular", withExtension: "ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return existing()
    }()

    private static func existing() -> Bool {
        #if canImport(UIKit)
        UIFont(name: name, size: 12) != nil
        #elseif canImport(AppKit)
        NSFont(name: name, size: 12) != nil
        #else
        false
        #endif
    }
}

extension Image {
    /// An SF Symbol drawn the way the system draws them. Call this before foregroundStyle.
    func symbol() -> some View {
        symbolRenderingMode(.hierarchical)
    }
}

struct Wordmark: View {
    var size: CGFloat = 34

    var body: some View {
        VStack(spacing: 2) {
            Text("Asteria").font(.asteria(size))
            Text("Keys").font(.reading(.title3, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asteria Keys")
    }
}
