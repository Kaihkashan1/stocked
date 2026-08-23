import SwiftUI

struct RecipeDetailView: View {
    let id: Int
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var showCookMode = false
    @State private var scale: Double = 1.0
    @State private var recategorizing = false
    @State private var recategorizeError: String?

    private var recipe: Recipe? { store.recipe(id: id) }

    var body: some View {
        Group {
            if let recipe {
                content(for: recipe)
            } else {
                Text("This recipe is no longer available.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .background(Theme.surface.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // Full immersion while reading a recipe — the fix for the floating
        // tab bar overlapping the last section (ingredients/steps/link).
        .toolbar(.hidden, for: .tabBar)
        // An opaque nav bar instead of the default transparent-over-content
        // one — with a full-bleed hero photo right below it, the
        // transparent/scrollEdge toolbar style is what let the ellipsis
        // menu's popover render behind the photo instead of above it.
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if let recipe {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.toggleFavorite(recipe) }
                    } label: {
                        Image(systemName: recipe.favorite ? "star.fill" : "star")
                    }
                    .tint(Theme.warm)
                    .accessibilityLabel(recipe.favorite ? "Remove from favorites" : "Add to favorites")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let url = recipe.sourceURL {
                            Link("Original post", destination: url)
                        }
                        Button("Edit") { showEdit = true }
                        Button("Recategorize") {
                            Task { await recategorize(recipe) }
                        }
                        Button("Delete", role: .destructive) { showDeleteConfirm = true }
                    } label: {
                        if recategorizing {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .disabled(deleting || recategorizing)
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let recipe {
                EditRecipeView(recipe: recipe)
                    .environmentObject(store)
            }
        }
        .fullScreenCover(isPresented: $showCookMode) {
            if let recipe {
                CookModeView(recipe: recipe)
            }
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let recipe {
                    Task { await delete(recipe) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from your Recipe Box. It stays out of Google Sheets too, but the row itself isn't removed.")
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { shown in if !shown { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Couldn't recategorize",
            isPresented: Binding(
                get: { recategorizeError != nil },
                set: { shown in if !shown { recategorizeError = nil } }
            ),
            presenting: recategorizeError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func delete(_ recipe: Recipe) async {
        deleting = true
        defer { deleting = false }
        if let error = await store.deleteRecipe(recipe) {
            deleteError = error
        } else {
            dismiss()
        }
    }

    private func recategorize(_ recipe: Recipe) async {
        recategorizing = true
        defer { recategorizing = false }
        if let error = await store.recategorizeRecipe(recipe) {
            recategorizeError = error
        }
    }

    private func content(for recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(for: recipe)
                VStack(alignment: .leading, spacing: 22) {
                    if !recipe.tags.isEmpty {
                        tags(for: recipe)
                    }
                    if !recipe.steps.isEmpty {
                        cookButton
                    }
                    if !recipe.ingredients.isEmpty {
                        ingredientsSection(for: recipe)
                    }
                    if !recipe.steps.isEmpty {
                        stepsSection(for: recipe)
                    }
                    if !recipe.notes.isEmpty {
                        notesSection(for: recipe)
                    }
                }
                .padding(20)
            }
        }
    }

    private func hero(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metaLine(for: recipe).uppercased())
                .font(Theme.mono(11))
                .tracking(0.5)
                .foregroundStyle(Theme.inkSoft)
            Text(recipe.title)
                .font(Theme.display(28, weight: .bold))
                .foregroundStyle(Theme.ink)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    private func metaLine(for recipe: Recipe) -> String {
        [recipe.cuisine, recipe.mealLabel, recipe.servings.map { "\($0) servings" }, recipe.time]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func tags(for recipe: Recipe) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(recipe.tags, id: \.self) { tag in
                Button {
                    store.tagFilter = tag
                    dismiss()
                } label: {
                    Text(tag)
                        .font(Theme.mono(12))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Theme.accentSoft)
                        .foregroundStyle(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cookButton: some View {
        Button {
            showCookMode = true
        } label: {
            Label("Start Cooking", systemImage: "play.fill")
                .font(Theme.mono(13, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Theme.accent)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }

    private func scaleControl() -> some View {
        HStack(spacing: 8) {
            Text("Scale")
                .font(Theme.mono(11.5, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
            ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { factor in
                Button {
                    scale = factor
                } label: {
                    Text(factor == floor(factor) ? "\(Int(factor))×" : "\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), factor))×")
                        .font(Theme.mono(11.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(scale == factor ? Theme.accent : Theme.surface2)
                        .foregroundStyle(scale == factor ? .white : Theme.inkSoft)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ingredientsSection(for recipe: Recipe) -> some View {
        let parsedLines = recipe.ingredients.map(splitIngredientQuantity)
        let canScale = parsedLines.contains { $0.quantity.flatMap { parseQuantityNumber(String($0.split(separator: " ").first ?? "")) } != nil }

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Ingredients")
            if canScale {
                scaleControl()
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedLines.enumerated()), id: \.offset) { index, parsed in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let quantity = parsed.quantity {
                            Text(scaledQuantity(quantity, by: scale))
                                .font(Theme.mono(12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(parsed.text)
                                .font(.body)
                                .foregroundStyle(Theme.ink)
                        } else {
                            Text(parsed.text)
                                .font(.body.italic())
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .padding(.vertical, 10)

                    if index < parsedLines.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
        }
    }

    private func stepsSection(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Steps")
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.accent)
                        .clipShape(Circle())
                    Text(step)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private func notesSection(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Notes")
            Text(recipe.notes)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warmSoft.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Theme.display(19, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }
}

/// Simple wrapping HStack for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }

        return (origins, CGSize(width: width, height: y + rowHeight))
    }
}
