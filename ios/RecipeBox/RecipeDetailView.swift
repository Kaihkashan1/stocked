import SwiftUI

struct RecipeDetailView: View {
    let id: Int
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var showCookMode = false
    @State private var showActionSheet = false

    private var recipe: Recipe? { store.recipe(id: id) }

    var body: some View {
        Group {
            if let recipe {
                content(for: recipe)
            } else {
                Text("This recipe is no longer available.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.neutral700)
                    .padding()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CircleIconButton(systemImage: "chevron.left", size: 40) { dismiss() }
                    .accessibilityLabel("Back")
            }
            if let recipe {
                // One toolbar item, not two — two adjacent ToolbarItems get
                // an automatic pill-grouping background on newer iOS. A
                // plain Button + confirmationDialog (rather than Menu, which
                // brings its own glass chrome) keeps these flat circles.
                trailingToolbarButtons(for: recipe)
            }
        }
        .sheet(isPresented: $showEdit) {
            if let recipe {
                EditRecipeView(recipe: recipe)
                    .environment(store)
            }
        }
        .fullScreenCover(isPresented: $showCookMode) {
            if let recipe {
                CookModeView(recipe: recipe)
            }
        }
        .confirmationDialog("Recipe", isPresented: $showActionSheet, titleVisibility: .hidden) {
            if let url = recipe?.sourceURL {
                Link("Original post", destination: url)
            }
            Button("Edit") { showEdit = true }
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
            Button("Cancel", role: .cancel) {}
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
    }

    /// A grouped ToolbarItem gets an automatic pill-grouping "glass"
    /// background on iOS 26+, which clashes with these already being their
    /// own flat circles — `sharedBackgroundVisibility(.hidden)` turns that
    /// off, but only exists on iOS 26+, so it's applied conditionally.
    @ToolbarContentBuilder
    private func trailingToolbarButtons(for recipe: Recipe) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItemGroup(placement: .topBarTrailing) {
                favoriteButton(for: recipe)
                moreButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                favoriteButton(for: recipe)
                moreButton
            }
        }
    }

    private func favoriteButton(for recipe: Recipe) -> some View {
        CircleIconButton(
            systemImage: recipe.favorite ? "star.fill" : "star",
            size: 40,
            foreground: recipe.favorite ? Theme.accent : Theme.neutral800
        ) {
            Task { await store.toggleFavorite(recipe) }
        }
        .accessibilityLabel(recipe.favorite ? "Remove from favorites" : "Add to favorites")
    }

    private var moreButton: some View {
        CircleIconButton(systemImage: "ellipsis", size: 40) {
            showActionSheet = true
        }
        .disabled(deleting)
        .accessibilityLabel("More")
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

    private func content(for recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(for: recipe)
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.top, 8)

                if !store.have.isEmpty {
                    pantryLine(for: recipe)
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.top, 14)
                }

                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    if !recipe.steps.isEmpty {
                        cookButton
                    }
                    if !recipe.ingredients.isEmpty {
                        IngredientsCard(recipe: recipe)
                    }
                    if !recipe.steps.isEmpty {
                        stepsSection(for: recipe)
                    }
                    if !recipe.notes.isEmpty {
                        notesSection(for: recipe)
                    }
                    if !recipe.tags.isEmpty {
                        tags(for: recipe)
                    }
                    sourceLine(for: recipe)
                }
                .padding(Theme.screenPadding)
                .padding(.bottom, 40)
            }
        }
    }

    private func hero(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let saved = recipe.savedAtRelativeLabel {
                Kicker(text: saved)
            }
            Text(recipe.title)
                .font(Theme.display(31))
                .foregroundStyle(Theme.ink)
            Text(recipe.course.rawValue)
                .font(Theme.body(11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(Theme.accent)
                .clipShape(Capsule())
                .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            DecorativeCircle(diameter: 170)
                .offset(x: 46, y: 58)
        }
        .clipShape(Rectangle())
        .cardBackground(radius: Theme.radiusContainer)
    }

    private func pantryLine(for recipe: Recipe) -> some View {
        let missing = missingIngredients(recipe, have: store.have)
        return Text(
            missing.isEmpty
                ? "You have everything for this."
                : "Missing \(missing.count): \(missing.joined(separator: ", "))"
        )
        .font(Theme.body(13))
        .foregroundStyle(Theme.sage800)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.sage100)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var cookButton: some View {
        Button {
            showCookMode = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start cooking")
            }
            .font(Theme.display(16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent)
            .clipShape(Capsule())
            .themeShadow(Theme.shadowSM)
        }
        .buttonStyle(.plain)
    }

    private func tags(for recipe: Recipe) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(recipe.tags, id: \.self) { tag in
                Button {
                    store.tagFilters = [tag]
                    dismiss()
                } label: {
                    Text(tag)
                        .font(Theme.body(11.5, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Theme.accent100)
                        .foregroundStyle(Theme.accent800)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "From Instagram" — deliberately the least prominent thing on the
    /// screen. Plain text when there's no link to attach (typed-in recipes).
    private func sourceLine(for recipe: Recipe) -> some View {
        Group {
            if let url = recipe.sourceURL {
                Link(destination: url) {
                    Text("From \(recipe.sourceLabel)")
                }
            } else {
                Text("From \(recipe.sourceLabel)")
            }
        }
        .font(Theme.body(12))
        .foregroundStyle(Theme.neutral600)
    }

    private func stepsSection(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Steps")
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(Theme.display(13))
                        .foregroundStyle(Theme.accent800)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent200)
                        .clipShape(Circle())
                    Text(step)
                        .font(Theme.body(14.5))
                        .lineSpacing(14.5 * 0.55)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private func notesSection(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: "Notes")
            Text(recipe.notes)
                .font(Theme.body(14))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.accent100)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Theme.display(23))
            .foregroundStyle(Theme.ink)
    }
}

/// Its own view rather than a function on RecipeDetailView, so that tapping
/// ½×/1×/2×/3× only re-renders this card. As a function, `scale` lived on
/// RecipeDetailView itself, so every scale change invalidated the *entire*
/// detail screen's body — re-running the regex-based quantity parsing over
/// every ingredient line on every tap, even though only this section's
/// output depends on scale.
private struct IngredientsCard: View {
    @Environment(PantryStore.self) private var pantry
    let recipe: Recipe
    @State private var scale: Double = 1.0

    /// Parsed once per recipe (here in init), not on every scale change.
    private let parsedLines: [IngredientLine]
    private let canScale: Bool

    init(recipe: Recipe) {
        self.recipe = recipe
        let parsed = recipe.ingredients.map(splitIngredientQuantity)
        parsedLines = parsed
        canScale = parsed.contains { $0.quantity.flatMap { parseQuantityNumber(String($0.split(separator: " ").first ?? "")) } != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients")
                    .font(Theme.display(23))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if canScale {
                    scaleControl
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedLines.enumerated()), id: \.offset) { index, parsed in
                    HStack(alignment: .center, spacing: 12) {
                        if let quantity = parsed.quantity {
                            Text(scaledQuantity(quantity, by: scale))
                                .font(Theme.body(12.5, weight: .semibold))
                                .foregroundStyle(scale == 1.0 ? Theme.accent800 : .white)
                                .frame(minWidth: 62)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(scale == 1.0 ? Theme.accent200 : Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Text(parsed.text)
                            .font(Theme.body(14.5))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        toBuyButton(for: parsed.text)
                    }
                    .padding(.vertical, 13)

                    if index < parsedLines.count - 1 {
                        Rectangle().fill(Theme.divider).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .cardBackground(radius: Theme.radiusRow)
        }
    }

    /// Round + / ✓ control — the only link from a recipe into the Pantry
    /// to-buy list. Toggles by ingredient text (case-insensitive).
    private func toBuyButton(for text: String) -> some View {
        let inList = pantry.isInToBuy(text)
        return Button {
            pantry.toggleToBuy(text: text)
        } label: {
            Image(systemName: inList ? "checkmark" : "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(inList ? Theme.bg : Theme.neutral700)
                .frame(width: 30, height: 30)
                .background(inList ? Theme.sage500 : Theme.neutral100)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inList ? "Remove \(text) from to-buy list" : "Add \(text) to to-buy list")
    }

    private var scaleControl: some View {
        HStack(spacing: 6) {
            ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { factor in
                Button {
                    scale = factor
                } label: {
                    Text(factor == floor(factor) ? "\(Int(factor))×" : "½×")
                        .font(Theme.body(12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(scale == factor ? Theme.accent : Theme.surface)
                        .foregroundStyle(scale == factor ? .white : Theme.neutral700)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Simple wrapping HStack for tags/chips.
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
