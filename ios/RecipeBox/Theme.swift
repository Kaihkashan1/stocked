import SwiftUI

/// Design tokens for the "Organic" redesign (see design_handoff_recipe_box/).
/// Replaces the old sage/grey palette and system-font stand-ins wholesale.
enum Theme {

    // MARK: - Color

    static let bg = Color(hex: 0xf5ead8)              // page ground
    static let surface = Color(hex: 0xebddc5)          // cards, fields
    static let ink = Color(hex: 0x201e1d)               // text

    static let accent = Color(hex: 0xc67139)            // terracotta
    static let accent600 = Color(hex: 0xb2622d)         // pressed
    static let accent700 = Color(hex: 0x8c491a)         // accent text
    static let accent800 = Color(hex: 0x643312)         // text on tint
    static let accent900 = Color(hex: 0x402310)         // cook mode bg
    /// Not given explicitly in the handoff table (only 100/200/300 tints and
    /// the 600/700/800/900 shades are). Interpolated between accent-300 and
    /// accent for the one place the spec calls for it: hover/pressed states
    /// and the step counter on the dark cook-mode screen.
    static let accent400 = Color(hex: 0xe29c6f)

    static let accent100 = Color(hex: 0xfff2eb)
    static let accent200 = Color(hex: 0xffe1d0)
    static let accent300 = Color(hex: 0xffc6a5)

    static let sage500 = Color(hex: 0x8fa073)
    static let sage300 = Color(hex: 0xccdbb2)
    static let sage100 = Color(hex: 0xf0fae1)
    static let sage800 = Color(hex: 0x3d472b)           // sage text
    /// Not in the handoff table (only 100/300/500/800 are) — interpolated
    /// between sage-300 and sage-500 for the one place it's called for: the
    /// dashed border on a pantry-suggestion chip.
    static let sage400 = Color(hex: 0xaebe93)

    /// From the Organic ramp (`_ds/.../styles.css`); not listed in the
    /// handoff table but used for amount chips, Add-to-buy buttons, and
    /// inactive tab glyphs.
    static let neutral100 = Color(hex: 0xf9f4ed)
    static let neutral200 = Color(hex: 0xeee7db)
    static let neutral300 = Color(hex: 0xdcd3c4)
    static let neutral400 = Color(hex: 0xc0b6a5)
    static let neutral500 = Color(hex: 0xa19786)
    static let neutral600 = Color(hex: 0x82796a)
    static let neutral700 = Color(hex: 0x645c50)
    static let neutral800 = Color(hex: 0x474238)
    static let neutral900 = Color(hex: 0x2e2b25)

    /// Expiry badge fill when an item expires within 3 days (Organic accent-500).
    static let accent500 = Color(hex: 0xd67f48)

    /// Hairline borders/dividers everywhere: ink at 16% opacity.
    static let divider = ink.opacity(0.16)

    /// The one dark screen (cook mode): warm-black ground, cream foreground.
    static let cookBg = accent900
    static let cookForeground = Color(hex: 0xf7ecd9)

    // MARK: - Type

    /// Caprasimo (regular 400) — every heading, title and button label.
    static func display(_ size: CGFloat) -> Font {
        .custom("Caprasimo-Regular", size: size)
    }

    /// Figtree (400/600/700) — body copy, labels, inputs. Weight snaps to
    /// the nearest of the three bundled static instances.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(figtreePostScriptName(for: weight), size: size)
    }

    private static func figtreePostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return "Figtree-Bold"
        case .semibold, .medium:
            return "Figtree-SemiBold"
        default:
            return "Figtree-Regular"
        }
    }

    // MARK: - Shape

    /// Containers (sheets, big cards): 28–32pt, 30 is the common case.
    static let radiusContainer: CGFloat = 30
    static let radiusCard: CGFloat = 30
    /// Smaller inline cards (rows, sub-cards) sit a touch tighter.
    static let radiusRow: CGFloat = 24
    /// The list screen's grid-mode recipe card — tighter than the list card.
    static let radiusCardGrid: CGFloat = 22

    // MARK: - Spacing

    static let screenPadding: CGFloat = 22
    static let cardGap: CGFloat = 13
    static let sectionGap: CGFloat = 22

    // MARK: - Shadow

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// `0 1 2 rgba(46,43,37,0.14)` — the everyday card/button shadow.
    static let shadowSM = ShadowStyle(color: neutral900.opacity(0.14), radius: 2, x: 0, y: 1)
    /// `0 3 10 rgba(46,43,37,0.16)` — heavier lift, e.g. the add-sheet.
    static let shadowMD = ShadowStyle(color: neutral900.opacity(0.16), radius: 10, x: 0, y: 3)
}

extension View {
    func themeShadow(_ style: Theme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
