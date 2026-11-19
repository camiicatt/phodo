import SwiftUI

/// A color the user can pick. Every preset is a single hue plus light or dark;
/// the whole palette (background, cards, photo tint, ink…) is derived from it
/// with fixed saturation/brightness steps, so every theme keeps the same contrast.
///
/// Light vs dark is part of the user's choice. phodo does NOT follow the
/// phone's dark-mode setting.
struct ThemePreset: Identifiable, Hashable {
    let id: String
    let hue: Double   // 0...1
    var dark = false

    var name: String { id }

    static let light: [ThemePreset] = [
        .init(id: "lavender", hue: 252 / 360),   // the default, matches the mockups
        .init(id: "sage",     hue: 110 / 360),
        .init(id: "peach",    hue: 22 / 360),
        .init(id: "sky",      hue: 205 / 360),
        .init(id: "butter",   hue: 48 / 360),
        .init(id: "rose",     hue: 340 / 360),
    ]

    static let darks: [ThemePreset] = [
        .init(id: "dusk",  hue: 252 / 360, dark: true),   // lavender, after sunset
        .init(id: "plum",  hue: 300 / 360, dark: true),
        .init(id: "moss",  hue: 120 / 360, dark: true),
        .init(id: "ocean", hue: 210 / 360, dark: true),
        .init(id: "cocoa", hue: 22 / 360,  dark: true),
        .init(id: "wine",  hue: 345 / 360, dark: true),
    ]

    static let all = light + darks
    static let lavender = light[0]

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
///
///   shade               → background of the "your people" and search sheets: a deeper
///                         tone of the page (deeper + richer in dark themes) so they feel
///                         like their own place
///   frame               → the mat around a full-screen photo: a deeper shade of the
///                         same hue (lighter in dark themes) so the picture stands out
struct Theme {
    let preset: ThemePreset
    let isDark: Bool

    let card: Color
    let chip: Color
    private(set) var bg: Color
    let sunken: Color
    let photoTint: Color
    let accent: Color
    let softInk: Color
    let ink: Color
    let frame: Color
    let shade: Color

    /// Same theme, but the page background is `shade` (for sheets that should stand apart).
    var shaded: Theme {
        var t = self
        t.bg = shade
        return t
    }

    init(preset: ThemePreset) {
        self.preset = preset
        self.isDark = preset.dark
        let s = Theme.steps(isDark: preset.dark)
        func c(_ step: (Double, Double)) -> Color {
            Color(hue: preset.hue, saturation: step.0, brightness: step.1)
        }
        card = c(s.card); chip = c(s.chip); bg = c(s.bg); sunken = c(s.sunken)
        photoTint = c(s.photoTint); accent = c(s.accent); softInk = c(s.softInk); ink = c(s.ink)
        frame = preset.dark ? c((0.32, 0.50)) : c((0.40, 0.72))
        shade = preset.dark ? c((0.42, 0.19)) : c((0.22, 0.915))
    }

    /// (saturation, brightness) for each token. Light values were measured from the
    /// lavender mockup hexes. Dark values are a soft "dusk", not near-black: the
    /// background sits around 26% brightness, with raised cards lighter than it.
    static func steps(isDark: Bool) -> (card: (Double, Double), chip: (Double, Double), bg: (Double, Double),
                                        sunken: (Double, Double), photoTint: (Double, Double), accent: (Double, Double),
                                        softInk: (Double, Double), ink: (Double, Double)) {
        if isDark {
            return (card: (0.30, 0.33), chip: (0.30, 0.31), bg: (0.34, 0.26), sunken: (0.36, 0.21),
                    photoTint: (0.30, 0.40), accent: (0.30, 0.82), softInk: (0.14, 0.80), ink: (0.05, 0.97))
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
