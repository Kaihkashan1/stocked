import SwiftUI
import UIKit

/// Full-screen, one-step-at-a-time cooking view. Keeps the screen awake
/// (idle timer disabled) for as long as it's on screen, since the whole
/// point is not having to keep unlocking a messy-handed phone.
struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var steps: [String] { recipe.steps }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            stepText
            Spacer()
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.ignoresSafeArea())
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
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 36, height: 36)
                    .background(Theme.surface2)
                    .clipShape(Circle())
            }
            Spacer()
            Text(recipe.title)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var stepText: some View {
        VStack(spacing: 18) {
            Text("STEP \(index + 1) OF \(steps.count)")
                .font(Theme.mono(12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.warm)
            Text(steps.indices.contains(index) ? steps[index] : "")
                .font(Theme.display(30, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .id(index)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.22), value: index)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { stepIndex in
                    Capsule()
                        .fill(stepIndex == index ? Theme.accent : Theme.surface2)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)

            HStack(spacing: 14) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .background(Theme.surface2)
                        .foregroundStyle(Theme.ink)
                        .clipShape(Circle())
                }
                .disabled(index == 0)
                .opacity(index == 0 ? 0.4 : 1)

                Button {
                    advance()
                } label: {
                    Text(index < steps.count - 1 ? "Next step" : "Done cooking")
                        .font(Theme.mono(14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
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
