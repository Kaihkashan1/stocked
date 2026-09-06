import SwiftUI

/// Shared building blocks for the Organic redesign — kept here so every
/// screen's chips, circular buttons and cards stay pixel-identical instead
/// of each view rolling its own.

/// The 40–42pt circular buttons used in every toolbar-equivalent: back,
/// settings, add, favorite, ellipsis, close.
struct CircleIconButton: View {
    private enum Glyph {
        case system(String)
        case lucide(LucideIcon.Kind, filled: Bool)
    }

    private let glyph: Glyph
    var size: CGFloat = 42
    var background: Color = Theme.surface
    var foreground: Color = Theme.neutral800
    var bordered: Bool = true
    /// Detail back button: inset ring (1pt divider, 1.5pt accent when pressed)
    /// so the stroke stays even at any scale. Other circles keep a 1pt border.
    var insetRing: Bool = false
    /// Ellipsis while its menu is open — accent ring, same as the handoff.
    var highlighted: Bool = false
    let action: () -> Void

    init(
        systemImage: String,
        size: CGFloat = 42,
        background: Color = Theme.surface,
        foreground: Color = Theme.neutral800,
        bordered: Bool = true,
        insetRing: Bool = false,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) {
        self.glyph = .system(systemImage)
        self.size = size
        self.background = background
        self.foreground = foreground
        self.bordered = bordered
        self.insetRing = insetRing
        self.highlighted = highlighted
        self.action = action
    }

    init(
        lucide: LucideIcon.Kind,
        size: CGFloat = 42,
        background: Color = Theme.surface,
        foreground: Color = Theme.neutral800,
        bordered: Bool = true,
        insetRing: Bool = false,
        highlighted: Bool = false,
        filled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.glyph = .lucide(lucide, filled: filled)
        self.size = size
        self.background = background
        self.foreground = foreground
        self.bordered = bordered
        self.insetRing = insetRing
        self.highlighted = highlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                switch glyph {
                case .system(let name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.4, weight: .semibold))
                case .lucide(let kind, let filled):
                    LucideIcon(kind, size: size * 0.45, filled: filled)
                }
            }
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(Circle())
        }
        .buttonStyle(CircleIconButtonStyle(bordered: bordered, insetRing: insetRing, highlighted: highlighted))
    }
}

private struct CircleIconButtonStyle: ButtonStyle {
    var bordered: Bool
    var insetRing: Bool
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if insetRing {
                    Circle().strokeBorder(
                        configuration.isPressed ? Theme.accent : Theme.divider,
                        lineWidth: configuration.isPressed ? 1.5 : 1
                    )
                    .padding(1)
                } else if bordered || highlighted {
                    Circle().strokeBorder(
                        highlighted || configuration.isPressed ? Theme.accent : Theme.divider,
                        lineWidth: 1
                    )
                }
            }
            .clipShape(Circle())
    }
}

/// A selectable capsule chip — the course row, filter chips, scale control,
/// tags, sort options. Selected = accent fill / cream text; unselected =
/// surface fill / neutral text / divider border. Pressed selected chips
/// ramp to accent-600.
struct ChipButton: View {
    let title: String
    let selected: Bool
    var font: Font = Theme.body(12.5, weight: .semibold)
    /// Sort pills sit in an equal-width HStack. Course / tag / language chips
    /// in a FlowLayout must size to their label — `maxWidth: .infinity` there
    /// reports a huge width, so later chips (Dips) wrap into a clipped row.
    var fillsWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(ChipButtonStyle(selected: selected))
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Theme.neutral800)
            .background(selected
                ? (configuration.isPressed ? Theme.accent600 : Theme.accent)
                : (configuration.isPressed ? Theme.neutral200 : Theme.surface))
            .overlay {
                if !selected {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
            .clipShape(Capsule())
    }
}

/// Full-width (or capsule) accent CTA — pressed state uses accent-600.
struct AccentFillButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    var pressedFill: Color = Theme.accent600
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(configuration.isPressed ? pressedFill : fill)
            .clipShape(Capsule())
    }
}

/// Destructive confirm fill (accent-800) with pressed darkening to
/// accent-900, cream label, and the everyday button shadow.
/// Font, padding, and max-width live in the style so iOS 26 glass chrome
/// cannot sit outside a tiny text-only capsule.
struct DestructiveFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0xfff8ec))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? Theme.accent900 : Theme.accent800)
            .clipShape(Capsule())
            .themeShadow(Theme.shadowSM)
    }
}

/// Cancel / secondary capsule — surface fill, divider border, darkens to
/// neutral-100 when pressed.
struct OutlinedCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14.5, weight: .semibold))
            .foregroundStyle(Theme.neutral800)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? Theme.neutral100 : Theme.surface)
            .overlay {
                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
            }
            .clipShape(Capsule())
    }
}

/// Numbered circle beside a step. Body font (not Caprasimo) so the digit
/// sits in the optical center; a small top offset lines the circle up with
/// the first line of wrapping step text rather than the row's vertical
/// midpoint.
struct StepNumberBadge: View {
    let number: Int
    var size: CGFloat = 28
    var fontSize: CGFloat = 13
    var topOffset: CGFloat = 2

    var body: some View {
        Text("\(number)")
            .font(Theme.body(fontSize, weight: .bold))
            .foregroundStyle(Theme.accent800)
            .frame(width: size, height: size)
            .background(Theme.accent200)
            .clipShape(Circle())
            .padding(.top, topOffset)
    }
}

/// Uppercase, tracked-out Figtree label used for every "kicker" — the small
/// line above a title ("6 RECIPES · 1 FAVORITE", "SAVED 2 DAYS AGO", ...).
struct Kicker: View {
    let text: String
    var size: CGFloat = 10.5
    var color: Color = Theme.accent700

    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "en")))
            .font(Theme.body(size, weight: .semibold))
            .tracking(size * 0.14)
            .foregroundStyle(color)
    }
}

/// The soft decorative circle behind headers/heroes — an accent or sage
/// tint, positioned off-canvas and clipped by the containing card/screen.
struct DecorativeCircle: View {
    var color: Color = Theme.accent200
    var diameter: CGFloat
    var opacity: Double = 1

    var body: some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: diameter, height: diameter)
    }
}

/// "Cards fade+rise in" — opacity 0→1, translateY 6→0, 0.3s ease, the first
/// time a view appears.
private struct FadeInOnAppear: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) { shown = true }
            }
    }
}

extension View {
    func fadeInOnAppear() -> some View {
        modifier(FadeInOnAppear())
    }
}

/// Strokes from `Recipe Box.dc.html` — Lucide-style, 24pt grid, round caps.
struct LucideIcon: View {
    enum Kind {
        case trash, gear, plus, search, sliders, grid, list
        case cookbook, cupboard, xmark, check, star, chevronLeft, chevronDown, ellipsis
    }

    let kind: Kind
    var size: CGFloat = 17
    /// Design uses 2.75 on toolbar glyphs and 2.5 on the small trash.
    var stroke: CGFloat = 2.75
    var filled: Bool = false

    init(_ kind: Kind, size: CGFloat = 17, stroke: CGFloat = 2.75, filled: Bool = false) {
        self.kind = kind
        self.size = size
        self.stroke = stroke
        self.filled = filled
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            var strokePath = Path()
            var fillPath = Path()
            switch kind {
            case .trash:
                strokePath.move(to: CGPoint(x: 5, y: 6))
                strokePath.addLine(to: CGPoint(x: 19, y: 6))
                strokePath.move(to: CGPoint(x: 9, y: 6))
                strokePath.addLine(to: CGPoint(x: 9, y: 4.5))
                strokePath.addQuadCurve(to: CGPoint(x: 10.5, y: 3), control: CGPoint(x: 9, y: 3))
                strokePath.addLine(to: CGPoint(x: 13.5, y: 3))
                strokePath.addQuadCurve(to: CGPoint(x: 15, y: 4.5), control: CGPoint(x: 15, y: 3))
                strokePath.addLine(to: CGPoint(x: 15, y: 6))
                strokePath.move(to: CGPoint(x: 17, y: 6))
                strokePath.addLine(to: CGPoint(x: 16.2, y: 19))
                strokePath.addQuadCurve(to: CGPoint(x: 14.2, y: 20.9), control: CGPoint(x: 16.2, y: 20.9))
                strokePath.addLine(to: CGPoint(x: 9.8, y: 20.9))
                strokePath.addQuadCurve(to: CGPoint(x: 7.8, y: 19), control: CGPoint(x: 7.8, y: 20.9))
                strokePath.addLine(to: CGPoint(x: 7, y: 6))
            case .gear:
                strokePath.addEllipse(in: CGRect(x: 8.8, y: 8.8, width: 6.4, height: 6.4))
                strokePath.move(to: CGPoint(x: 12, y: 2.5))
                strokePath.addLine(to: CGPoint(x: 12, y: 4.5))
                strokePath.move(to: CGPoint(x: 12, y: 19.5))
                strokePath.addLine(to: CGPoint(x: 12, y: 21.5))
                strokePath.move(to: CGPoint(x: 2.5, y: 12))
                strokePath.addLine(to: CGPoint(x: 4.5, y: 12))
                strokePath.move(to: CGPoint(x: 19.5, y: 12))
                strokePath.addLine(to: CGPoint(x: 21.5, y: 12))
                strokePath.move(to: CGPoint(x: 5.2, y: 5.2))
                strokePath.addLine(to: CGPoint(x: 6.7, y: 6.7))
                strokePath.move(to: CGPoint(x: 17.3, y: 17.3))
                strokePath.addLine(to: CGPoint(x: 18.8, y: 18.8))
                strokePath.move(to: CGPoint(x: 18.8, y: 5.2))
                strokePath.addLine(to: CGPoint(x: 17.3, y: 6.7))
                strokePath.move(to: CGPoint(x: 6.7, y: 17.3))
                strokePath.addLine(to: CGPoint(x: 5.2, y: 18.8))
            case .plus:
                strokePath.move(to: CGPoint(x: 12, y: 5))
                strokePath.addLine(to: CGPoint(x: 12, y: 19))
                strokePath.move(to: CGPoint(x: 5, y: 12))
                strokePath.addLine(to: CGPoint(x: 19, y: 12))
            case .search:
                strokePath.addEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
                strokePath.move(to: CGPoint(x: 21, y: 21))
                strokePath.addLine(to: CGPoint(x: 16.7, y: 16.7))
            case .sliders:
                strokePath.move(to: CGPoint(x: 4, y: 7))
                strokePath.addLine(to: CGPoint(x: 20, y: 7))
                strokePath.move(to: CGPoint(x: 7, y: 12))
                strokePath.addLine(to: CGPoint(x: 17, y: 12))
                strokePath.move(to: CGPoint(x: 10, y: 17))
                strokePath.addLine(to: CGPoint(x: 14, y: 17))
            case .grid:
                strokePath.addPath(Self.roundedRect(x: 3.5, y: 3.5, w: 7.5, h: 7.5, r: 1.8))
                strokePath.addPath(Self.roundedRect(x: 13, y: 3.5, w: 7.5, h: 7.5, r: 1.8))
                strokePath.addPath(Self.roundedRect(x: 3.5, y: 13, w: 7.5, h: 7.5, r: 1.8))
                strokePath.addPath(Self.roundedRect(x: 13, y: 13, w: 7.5, h: 7.5, r: 1.8))
            case .list:
                strokePath.move(to: CGPoint(x: 4, y: 6.5))
                strokePath.addLine(to: CGPoint(x: 20, y: 6.5))
                strokePath.move(to: CGPoint(x: 4, y: 12))
                strokePath.addLine(to: CGPoint(x: 20, y: 12))
                strokePath.move(to: CGPoint(x: 4, y: 17.5))
                strokePath.addLine(to: CGPoint(x: 20, y: 17.5))
            case .cookbook:
                strokePath.move(to: CGPoint(x: 4, y: 5.5))
                strokePath.addQuadCurve(to: CGPoint(x: 6, y: 3.5), control: CGPoint(x: 4, y: 3.5))
                strokePath.addLine(to: CGPoint(x: 11, y: 3.5))
                strokePath.addQuadCurve(to: CGPoint(x: 14, y: 6.5), control: CGPoint(x: 14, y: 3.5))
                strokePath.addLine(to: CGPoint(x: 14, y: 20))
                strokePath.addQuadCurve(to: CGPoint(x: 11.5, y: 17.5), control: CGPoint(x: 14, y: 17.5))
                strokePath.addLine(to: CGPoint(x: 4, y: 17.5))
                strokePath.closeSubpath()
                strokePath.move(to: CGPoint(x: 20, y: 5.5))
                strokePath.addQuadCurve(to: CGPoint(x: 18, y: 3.5), control: CGPoint(x: 20, y: 3.5))
                strokePath.addLine(to: CGPoint(x: 13, y: 3.5))
                strokePath.addQuadCurve(to: CGPoint(x: 10, y: 6.5), control: CGPoint(x: 10, y: 3.5))
                strokePath.addLine(to: CGPoint(x: 10, y: 20))
                strokePath.addQuadCurve(to: CGPoint(x: 12.5, y: 17.5), control: CGPoint(x: 10, y: 17.5))
                strokePath.addLine(to: CGPoint(x: 20, y: 17.5))
                strokePath.closeSubpath()
            case .cupboard:
                strokePath.addPath(Self.roundedRect(x: 4.5, y: 3, w: 15, h: 18, r: 2))
                strokePath.move(to: CGPoint(x: 12, y: 3))
                strokePath.addLine(to: CGPoint(x: 12, y: 21))
                fillPath.addEllipse(in: CGRect(x: 9.3, y: 11.1, width: 1.8, height: 1.8))
                fillPath.addEllipse(in: CGRect(x: 12.9, y: 11.1, width: 1.8, height: 1.8))
            case .xmark:
                strokePath.move(to: CGPoint(x: 18, y: 6))
                strokePath.addLine(to: CGPoint(x: 6, y: 18))
                strokePath.move(to: CGPoint(x: 6, y: 6))
                strokePath.addLine(to: CGPoint(x: 18, y: 18))
            case .check:
                strokePath.move(to: CGPoint(x: 20, y: 6))
                strokePath.addLine(to: CGPoint(x: 9, y: 17))
                strokePath.addLine(to: CGPoint(x: 4, y: 12))
            case .star:
                strokePath.move(to: CGPoint(x: 12, y: 3.2))
                strokePath.addLine(to: CGPoint(x: 14.7, y: 8.7))
                strokePath.addLine(to: CGPoint(x: 20.7, y: 9.6))
                strokePath.addLine(to: CGPoint(x: 16.35, y: 13.84))
                strokePath.addLine(to: CGPoint(x: 17.38, y: 19.84))
                strokePath.addLine(to: CGPoint(x: 12, y: 17.01))
                strokePath.addLine(to: CGPoint(x: 6.62, y: 19.84))
                strokePath.addLine(to: CGPoint(x: 7.65, y: 13.84))
                strokePath.addLine(to: CGPoint(x: 3.3, y: 9.6))
                strokePath.addLine(to: CGPoint(x: 9.3, y: 8.7))
                strokePath.closeSubpath()
            case .chevronLeft:
                strokePath.move(to: CGPoint(x: 15, y: 5))
                strokePath.addLine(to: CGPoint(x: 8, y: 12))
                strokePath.addLine(to: CGPoint(x: 15, y: 19))
            case .chevronDown:
                strokePath.move(to: CGPoint(x: 6, y: 9))
                strokePath.addLine(to: CGPoint(x: 12, y: 15))
                strokePath.addLine(to: CGPoint(x: 18, y: 9))
            case .ellipsis:
                fillPath.addEllipse(in: CGRect(x: 3.1, y: 10.1, width: 3.8, height: 3.8))
                fillPath.addEllipse(in: CGRect(x: 10.1, y: 10.1, width: 3.8, height: 3.8))
                fillPath.addEllipse(in: CGRect(x: 17.1, y: 10.1, width: 3.8, height: 3.8))
            }
            let t = CGAffineTransform(scaleX: scale, y: scale)
            let scaledStroke = strokePath.applying(t)
            if filled {
                context.fill(scaledStroke, with: .foreground)
            }
            context.stroke(
                scaledStroke,
                with: .foreground,
                style: StrokeStyle(lineWidth: stroke * scale, lineCap: .round, lineJoin: .round)
            )
            if !fillPath.isEmpty {
                context.fill(fillPath.applying(t), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func roundedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }
}

/// 30pt hit target around the design's 15pt trash glyph.
struct LucideTrashButton: View {
    let accessibilityLabel: String
    var frame: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(.trash, size: 15, stroke: 2.5)
                .foregroundStyle(Theme.neutral500)
                .frame(width: frame, height: frame)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Lucide strokes from the detail ⋯ menu (17pt, stroke 2.5 in a 24pt grid).
/// SF Symbols on the ellipsis button were leaking into the overlay and no
/// longer matched the handoff.
struct HandoffMenuIcon: View {
    enum Kind {
        case originalPost, edit, trash
    }

    let kind: Kind
    var size: CGFloat = 17

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            var path = Path()
            switch kind {
            case .originalPost:
                path.addPath(Self.roundedRect(x: 7, y: 8, w: 11, h: 12, r: 2))
                path.move(to: CGPoint(x: 14, y: 5))
                path.addLine(to: CGPoint(x: 19, y: 5))
                path.addLine(to: CGPoint(x: 19, y: 10))
                path.move(to: CGPoint(x: 19, y: 5))
                path.addLine(to: CGPoint(x: 11, y: 13))
            case .edit:
                path.move(to: CGPoint(x: 12, y: 20))
                path.addLine(to: CGPoint(x: 21, y: 20))
                path.move(to: CGPoint(x: 16.5, y: 3.5))
                path.addQuadCurve(to: CGPoint(x: 19.5, y: 6.5), control: CGPoint(x: 18.7, y: 3.5))
                path.addLine(to: CGPoint(x: 7, y: 19))
                path.addLine(to: CGPoint(x: 3, y: 20))
                path.addLine(to: CGPoint(x: 4, y: 16))
                path.closeSubpath()
            case .trash:
                path.move(to: CGPoint(x: 5, y: 6))
                path.addLine(to: CGPoint(x: 19, y: 6))
                path.move(to: CGPoint(x: 9, y: 6))
                path.addLine(to: CGPoint(x: 9, y: 4.5))
                path.addQuadCurve(to: CGPoint(x: 10.5, y: 3), control: CGPoint(x: 9, y: 3))
                path.addLine(to: CGPoint(x: 13.5, y: 3))
                path.addQuadCurve(to: CGPoint(x: 15, y: 4.5), control: CGPoint(x: 15, y: 3))
                path.addLine(to: CGPoint(x: 15, y: 6))
                path.move(to: CGPoint(x: 17, y: 6))
                path.addLine(to: CGPoint(x: 16.2, y: 19))
                path.addQuadCurve(to: CGPoint(x: 14.2, y: 20.9), control: CGPoint(x: 16.2, y: 20.9))
                path.addLine(to: CGPoint(x: 9.8, y: 20.9))
                path.addQuadCurve(to: CGPoint(x: 7.8, y: 19), control: CGPoint(x: 7.8, y: 20.9))
                path.addLine(to: CGPoint(x: 7, y: 6))
            }
            let t = CGAffineTransform(scaleX: scale, y: scale)
            let scaled = path.applying(t)
            context.stroke(
                scaled,
                with: .foreground,
                style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
    }

    private static func roundedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }
}

/// A single labelled row in the Settings Import limits section — a 6pt capsule
/// track (neutral-200) with an accent fill proportional to `used / limit`.
struct UsageBar: View {
    let label: String
    let valueText: String
    let used: Double
    let limit: Double
    /// "Resets around midnight Pacific" / "Resets Sep 15" — nil omits the
    /// line entirely rather than showing a blank gap.
    var resetText: String? = nil

    private var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(valueText)
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.neutral700)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.neutral200)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            if let resetText {
                Text(resetText)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.neutral600)
            }
        }
    }
}

/// Surface card background with the standard corner radius + shadow-sm.
extension View {
    func cardBackground(radius: CGFloat = Theme.radiusCard, fill: Color = Theme.surface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .themeShadow(Theme.shadowSM)
    }

    /// Clips to a rounded rect without the shadow — for content that sits
    /// inside an already-shadowed container.
    func roundedCorners(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Suggested tag chips plus a field to type a new one. Used on Add and Edit
/// only — Filters has no create control.
struct TagPicker: View {
    @Binding var selected: Set<String>
    var extraTags: [String] = []
    @State private var draft = ""

    private var offered: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in recipeTags + extraTags + selected.sorted() {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                ordered.append(tag)
            }
        }
        return ordered
    }

    private var canAddDraft: Bool {
        guard let tag = normalizeRecipeTag(draft) else { return false }
        return !selected.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
            && selected.count < maxRecipeTags
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(offered, id: \.self) { tag in
                    ChipButton(title: localizedRecipeTag(tag), selected: selected.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })) {
                        toggle(tag)
                    }
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                TextField(L("New tag"), text: $draft)
                    .font(Theme.body(13.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { addDraft() }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(Theme.surface)
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    .clipShape(Capsule())

                Button(action: addDraft) {
                    Text(L("Add tag"))
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(canAddDraft ? Theme.accent800 : Theme.neutral400)
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .background(canAddDraft ? Theme.accent100 : Theme.surface)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canAddDraft)
            }
        }
    }

    private func toggle(_ tag: String) {
        if let existing = selected.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            selected.remove(existing)
        } else if selected.count < maxRecipeTags, let normalized = normalizeRecipeTag(tag) {
            selected.insert(normalized)
        }
    }

    private func addDraft() {
        guard let tag = normalizeRecipeTag(draft), canAddDraft else { return }
        // `offered` already includes every entry in `selected`, so this chip
        // shows up immediately without needing to tell RecipeStore about it —
        // it becomes visible everywhere else (Filters, other Add/Edit
        // sheets) once the recipe carrying it is actually saved, not before.
        // Remembering it globally the moment it's typed used to leave a
        // permanent, matches-nothing chip in Filters if the sheet was
        // cancelled instead of saved.
        selected.insert(tag)
        draft = ""
    }
}
