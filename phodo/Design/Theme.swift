import SwiftUI

/// A color the user can pick. Every preset is a single hue; the whole palette
/// (background, cards, photo tint, ink…) is derived from it with fixed
/// saturation/brightness steps, so every theme keeps the same contrast.
struct ThemePreset: Identifiable, Hashable {
    let id: String
    let hue: Double   // 0...1

    var name: String { id }

    static let all: [ThemePreset] = [
        .init(id: "lavender", hue: 252 / 360),   // the default, matches the mockups
        .init(id: "sage",     hue: 110 / 360),
        .init(id: "peach",    hue: 22 / 360),
        .init(id: "sky",      hue: 205 / 360),
        .init(id: "butter",   hue: 48 / 360),
        .init(id: "rose",     hue: 340 / 360),
    ]

    static let lavender = all[0]

    static func find(_ id: String) -> ThemePreset {
        all.first { $0.id == id } ?? .lavender
    }
}

/// The brightness ramp (Samuel's feedback: same hue, different brightness levels
/// so elements stay distinct).
///
///   card      lightest  → raised things: cards, sheets
///   chip                → unselected chips, toggle tracks
///   bg                  → page background (#DCD5F5 for lavender)
///   sunken              → drop zone, empty calendar days
///   photoTint           → photo placeholders (#C4BAEA)
///   accent              → focus, "today" marker
///   softInk             → secondary text (#4A4560)
///   ink       darkest   → text, 1px lines, primary buttons (#1C1A27)
struct Theme {
    let preset: ThemePreset
    let isDark: Bool

    let card: Color
    let chip: Color
    let bg: Color
    let sunken: Color
    let photoTint: Color
    let accent: Color
    let softInk: Color
    let ink: Color

    init(preset: ThemePreset, isDark: Bool = false) {
        self.preset = preset
        self.isDark = isDark
        let s = Theme.steps(isDark: isDark)
        func c(_ step: (Double, Double)) -> Color {
            Color(hue: preset.hue, saturation: step.0, brightness: step.1)
        }
        card = c(s.card); chip = c(s.chip); bg = c(s.bg); sunken = c(s.sunken)
        photoTint = c(s.photoTint); accent = c(s.accent); softInk = c(s.softInk); ink = c(s.ink)
    }

    /// (saturation, brightness) for each token. Light values were measured from the
    /// lavender mockup hexes; dark values invert the ramp.
    static func steps(isDark: Bool) -> (card: (Double, Double), chip: (Double, Double), bg: (Double, Double),
                                        sunken: (Double, Double), photoTint: (Double, Double), accent: (Double, Double),
                                        softInk: (Double, Double), ink: (Double, Double)) {
        if isDark {
            return (card: (0.28, 0.17), chip: (0.26, 0.21), bg: (0.30, 0.12), sunken: (0.32, 0.09),
                    photoTint: (0.30, 0.26), accent: (0.35, 0.85), softInk: (0.12, 0.72), ink: (0.06, 0.95))
        }
        return (card: (0.05, 0.99), chip: (0.09, 0.98), bg: (0.13, 0.96), sunken: (0.175, 0.94),
                photoTint: (0.21, 0.92), accent: (0.35, 0.77), softInk: (0.28, 0.38), ink: (0.33, 0.15))
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(preset: .lavender)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Fonts. Uses Bricolage Grotesque / DM Mono when the font files are bundled
/// (see docs/ARCHITECTURE.md → "fonts"), otherwise falls back to system fonts.
enum PhFont {
    static func title(_ size: CGFloat = 44) -> Font {
        custom("BricolageGrotesque-ExtraBold", size, .largeTitle) ?? .system(size: size, weight: .heavy)
    }
    static func bold(_ size: CGFloat = 17) -> Font {
        custom("BricolageGrotesque-Bold", size, .headline) ?? .system(size: size, weight: .bold)
    }
    static func body(_ size: CGFloat = 17) -> Font {
        custom("BricolageGrotesque-Regular", size, .body) ?? .system(size: size)
    }
    static func mono(_ size: CGFloat = 14) -> Font {
        custom("DMMono-Regular", size, .caption) ?? .system(size: size, design: .monospaced)
    }

    private static func custom(_ name: String, _ size: CGFloat, _ style: Font.TextStyle) -> Font? {
        UIFont(name: name, size: size) == nil ? nil : .custom(name, size: size, relativeTo: style)
    }
}

enum Metrics {
    static let margin: CGFloat = 22
    static let radius: CGFloat = 20
    static let line: CGFloat = 1
}
