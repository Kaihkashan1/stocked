import SwiftUI

/// Shared building blocks for the Organic redesign — kept here so every
/// screen's chips, circular buttons and cards stay pixel-identical instead
/// of each view rolling its own.

/// The 40–42pt circular buttons used in every toolbar-equivalent: back,
/// settings, add, favorite, ellipsis, close.
struct CircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 42
    var background: Color = Theme.surface
    var foreground: Color = Theme.neutral800
    var bordered: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay {
                    if bordered {
                        Circle().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A selectable capsule chip — the course row, filter chips, scale control,
/// tags, sort options. Selected = accent fill / cream text; unselected =
/// surface fill / neutral text / divider border.
struct ChipButton: View {
    let title: String
    let selected: Bool
    var font: Font = Theme.body(12.5, weight: .semibold)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(selected ? .white : Theme.neutral800)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(selected ? Theme.accent : Theme.surface)
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Uppercase, tracked-out Figtree label used for every "kicker" — the small
/// line above a title ("6 RECIPES · 1 FAVORITE", "SAVED 2 DAYS AGO", ...).
struct Kicker: View {
    let text: String
    var size: CGFloat = 10.5
    var color: Color = Theme.accent700

    var body: some View {
        Text(text.uppercased())
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

/// A single labelled row in the Settings "API usage" card — a 6pt capsule
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
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(valueText)
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.neutral600)
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
