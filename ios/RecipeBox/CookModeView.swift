import SwiftUI
import UIKit

/// Full-screen, one-step-at-a-time cooking view — the one dark screen in
/// the app. Keeps the screen awake (idle timer disabled) for as long as
/// it's on screen, since the whole point is not having to keep unlocking a
/// messy-handed phone.
struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    /// Whether the current step's text has been scrolled all the way to its
    /// bottom — used to fade out the "more below" hint once there's nothing
    /// left it's hiding. Reset whenever the step changes.
    @State private var atStepEnd = false

    private var steps: [String] { recipe.steps }
    private var currentStep: String { steps.indices.contains(index) ? steps[index] : "" }

    /// Longer steps get a smaller Caprasimo size so more of the text fits
    /// before scrolling is needed, instead of one fixed size for every
    /// step regardless of length. Same breakpoints as the design prototype.
    private var stepFontSize: CGFloat {
        switch currentStep.count {
        case ...70: return 32
        case ...120: return 27
        case ...190: return 23
        default: return 20
        }
    }

    /// A step long enough to likely need scrolling gets a soft fade at the
    /// bottom hinting there's more below — hidden again once actually
    /// scrolled to the end.
    private var showsScrollHint: Bool {
        currentStep.count > 300 && !atStepEnd
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.cookBg.ignoresSafeArea()
            Circle()
                .fill(Theme.accent.opacity(0.18))
                .frame(width: 260, height: 260)
                .offset(x: -70, y: -90)

            VStack(spacing: 0) {
                header
                stepArea
                controls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -40 {
                        advance()
                    } else if value.translation.width > 40 {
                        goBack()
                    }
                }
        )
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                LucideIcon(.xmark, size: 16)
                    .foregroundStyle(Theme.cookForeground)
                    .frame(width: 40, height: 40)
                    .background(Theme.cookForeground.opacity(0.14))
                    .clipShape(Circle())
            }
            Spacer()
            Text(recipe.title.uppercased(with: Locale(identifier: "en")))
                .font(Theme.body(12, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.cookForeground.opacity(0.65))
                .lineLimit(1)
            Spacer()
            Button {
                goBack()
            } label: {
                LucideIcon(.chevronLeft, size: 16)
                    .foregroundStyle(Theme.cookForeground)
                    .frame(width: 40, height: 40)
                    .background(Theme.cookForeground.opacity(0.14))
                    .clipShape(Circle())
            }
            .opacity(index == 0 ? 0.4 : 1)
            .disabled(index == 0)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 16)
    }

    /// Replaces a fixed Spacer/text/Spacer trio that just centered every
    /// step regardless of length: a single flexible region that still
    /// centers a short step, but scrolls (with a fade hint) once a step is
    /// long enough to overflow the space between the header and controls.
    private var stepArea: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    Text(L("Step \(index + 1) of \(steps.count)").uppercased(with: Locale(identifier: "en")))
                        .font(Theme.body(12, weight: .semibold))
                        .tracking(2.4)
                        .foregroundStyle(Theme.accent400)
                    Text(currentStep)
                        .font(Theme.display(stepFontSize))
                        .multilineTextAlignment(.center)
                        .lineSpacing(stepFontSize * 0.24)
                        .foregroundStyle(Theme.cookForeground)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                .padding(.horizontal, 32)
                .background(
                    GeometryReader { content in
                        Color.clear.preference(
                            key: StepScrollOffsetKey.self,
                            value: content.frame(in: .named("cookStepScroll")).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: "cookStepScroll")
            .onPreferenceChange(StepScrollOffsetKey.self) { maxY in
                atStepEnd = maxY <= proxy.size.height + 2
            }
            .mask(stepFadeMask)
        }
        .frame(maxWidth: .infinity)
        .id(index)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: index)
        .onChange(of: index) { _, _ in atStepEnd = false }
    }

    private var stepFadeMask: some View {
        Group {
            if showsScrollHint {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.78),
                        .init(color: .white.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.white
            }
        }
    }

    /// One fixed-position primary button for the whole session — nothing
    /// else may sit beside it. Progress ticks sit above it, unchanged.
    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { stepIndex in
                    Capsule()
                        .fill(stepIndex <= index ? Theme.accent : Theme.cookForeground.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 32)

            Button {
                advance()
            } label: {
                Text(index < steps.count - 1 ? L("Next step") : L("Done cooking"))
                    .font(Theme.display(16))
                    .foregroundStyle(Theme.cookForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 24)
        }
    }

    private func advance() {
        if index < steps.count - 1 {
            index += 1
        } else {
            dismiss()
        }
    }

    private func goBack() {
        if index > 0 { index -= 1 }
    }
}

private struct StepScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
