import SwiftUI
import UIKit

/// Screen 4 from the handoff — paste a link (an Instagram reel, a YouTube/
/// TikTok video, or any recipe page) instead of going through the
/// Shortcut's share sheet. POSTs to the same /ingest endpoint the Shortcut
/// uses, with the same X-Recipe-Box-Key header.
struct PasteALinkView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Called with the new recipe's id once the user taps "Open the
    /// recipe" — the caller dismisses this sheet and navigates there.
    var onOpenRecipe: (Int) -> Void

    @State private var urlText = ""
    @State private var phase: LinkPhase = .idle
    @State private var fetchStep = 0
    @State private var fetchStepTask: Task<Void, Never>?
    @State private var importJobID: UUID?

    private var fetchingMessages: [String] {
        [
            L("Fetching the post"),
            L("Reading the recipe…"),
            L("Saving to your box"),
        ]
    }

    private enum LinkPhase: Equatable {
        case idle
        case fetching
        case done(Recipe)
        case error(String)
    }

    /// A leading number keeps a range like "2-3" from being scaled unless it
    /// starts with a plain number — same idea applied here: only a real
    /// http(s) URL with a host counts as "detected".
    private var detectedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return url
    }

    var body: some View {
        let _ = currentImportStatus
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste a link")
                            .font(Theme.display(30))
                            .foregroundStyle(Theme.ink)
                        Text("A reel, a video, or any recipe page. We read it and fill the card in for you.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.neutral700)
                    }

                    urlRow

                    if let detectedURL, phase == .idle {
                        detectedPill(for: detectedURL)
                    }

                    if phase == .fetching {
                        fetchingCard
                        Text("You can close this. Import continues in the background.")
                            .font(Theme.body(12.5))
                            .foregroundStyle(Theme.neutral700)
                    }

                    if case .done(let recipe) = phase {
                        doneCard(for: recipe)
                    }

                    if case .error(let message) = phase {
                        Text(message)
                            .font(Theme.body(12.5))
                            .foregroundStyle(.red)
                    }

                    primaryButton

                    Text("Sharing from the app's share sheet still works exactly as before — this is for when the link is already on your clipboard.")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.neutral600)
                }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Theme.bg.ignoresSafeArea())
        .onDisappear { fetchStepTask?.cancel() }
        .onChange(of: currentImportStatus) { _, _ in
            syncPhase(from: store.importJobs)
        }
    }

    private var header: some View {
        HStack {
            Button(phase == .fetching ? L("Close") : L("Cancel")) { dismiss() }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.neutral700)
            Spacer()
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 16)
        .background(Theme.bg)
    }

    private var urlRow: some View {
        HStack(spacing: 10) {
            TextField("https://…", text: $urlText)
                .font(Theme.body(14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(phase == .fetching)
                .padding(.horizontal, 18)
                .frame(height: 50)
                .background(Theme.surface)
                .clipShape(Capsule())

            Button {
                if let clip = UIPasteboard.general.string {
                    urlText = clip
                    phase = .idle
                }
            } label: {
                Text("Paste")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(Theme.accent100)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func detectedPill(for url: URL) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            Text(detectedSourceLine(for: url))
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(Theme.accent700)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.accent100)
        .clipShape(Capsule())
    }

    private var fetchingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fetchingMessages.enumerated()), id: \.offset) { index, message in
                HStack(spacing: 12) {
                    RingSpinner(state: index < fetchStep ? .done : (index == fetchStep ? .active : .pending))
                    Text(message)
                        .font(Theme.body(14, weight: index == fetchStep ? .semibold : .regular))
                        .foregroundStyle(
                            index == fetchStep ? Theme.ink : (index < fetchStep ? Theme.sage800 : Theme.neutral600)
                        )
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < fetchingMessages.count - 1 {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .cardBackground(radius: Theme.radiusRow)
    }

    private func doneCard(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: L("Saved to your box"), color: Theme.sage800)
            Text(recipe.title)
                .font(Theme.display(21))
                .foregroundStyle(Theme.ink)
            Text(statsLine(for: recipe))
                .font(Theme.body(13))
                .foregroundStyle(Theme.sage800)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.sage100)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    /// Used to read "7 ingredients · 5 steps · 15 min" — the trailing time
    /// segment is gone along with the sheet's Time column.
    private func statsLine(for recipe: Recipe) -> String {
        [
            L("\(ingredientItemLines(recipe.ingredients).count) ingredients"),
            L("\(recipe.steps.count) steps"),
        ].joined(separator: " · ")
    }

    private var primaryButton: some View {
        Button {
            switch phase {
            case .idle, .error:
                startFetch()
            case .fetching:
                break
            case .done(let recipe):
                onOpenRecipe(recipe.id)
            }
        } label: {
            Text(primaryLabel)
                .font(Theme.display(16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isPrimaryDisabled ? Theme.neutral400 : Theme.accent)
                .clipShape(Capsule())
                .themeShadow(Theme.shadowSM)
        }
        .buttonStyle(.plain)
        .disabled(isPrimaryDisabled)
    }

    private var primaryLabel: String {
        switch phase {
        case .idle, .error: L("Save recipe")
        case .fetching: L("Reading…")
        case .done: L("Open the recipe")
        }
    }

    private var isPrimaryDisabled: Bool {
        switch phase {
        case .fetching: true
        case .idle, .error: detectedURL == nil
        case .done: false
        }
    }

    private var currentImportStatus: BackgroundImportJob.Status? {
        guard let importJobID else { return nil }
        return store.importJobs.first(where: { $0.id == importJobID })?.status
    }

    /// Drives the three fetching-card rows through their messages on a
    /// timer while the real POST /ingest request is in flight — the
    /// endpoint gives no incremental progress of its own, and the spec
    /// calls for showing this state "for the whole wait" (up to Vercel's
    /// 60s ceiling), so the alternative is a bare spinner for a minute.
    private func startFetch() {
        guard let url = detectedURL else { return }
        phase = .fetching
        fetchStep = 0
        fetchStepTask?.cancel()
        fetchStepTask = Task {
            for step in 1...(fetchingMessages.count - 1) {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                fetchStep = step
            }
        }
        importJobID = store.startLinkImport(url.absoluteString)
    }

    private func syncPhase(from jobs: [BackgroundImportJob]) {
        guard let importJobID, let job = jobs.first(where: { $0.id == importJobID }) else { return }
        switch job.status {
        case .running:
            break
        case .saved(let recipeID, _):
            fetchStepTask?.cancel()
            if let recipe = store.recipe(id: recipeID) {
                phase = .done(recipe)
                store.consumeImportJob(id: importJobID)
            }
        case .failed(let message):
            fetchStepTask?.cancel()
            phase = .error(message)
        case .photoReady:
            break
        }
    }
}

/// The 22pt ring spinner next to each fetching-card row: a plain neutral
/// ring while pending, a spinning accent arc while active, a solid sage
/// ring once that step is done.
private struct RingSpinner: View {
    enum SpinnerState { case pending, active, done }
    let state: SpinnerState

    @State private var rotating = false

    var body: some View {
        Group {
            switch state {
            case .pending:
                Circle().stroke(Theme.neutral200, lineWidth: 3)
            case .done:
                Circle().stroke(Theme.sage500, lineWidth: 3)
            case .active:
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            rotating = true
                        }
                    }
            }
        }
        .frame(width: 22, height: 22)
    }
}
