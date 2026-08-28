import SwiftUI

struct RecipeDetailView: View {
    let id: Int
    @Environment(RecipeStore.self) private var store
    @Environment(PantryStore.self) private var pantry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var showCookMode = false
    @State private var showMoreMenu = false

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
                // plain Button keeps these flat circles.
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
        .overlay {
            if showMoreMenu {
                moreMenuOverlay
            }
            if showDeleteConfirm {
                deleteConfirmOverlay
            }
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
            "Couldn't save",
            isPresented: Binding(
                get: { pantry.actionError != nil },
                set: { shown in if !shown { pantry.actionError = nil } }
            ),
            presenting: pantry.actionError
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
            showMoreMenu = true
        }
        .disabled(deleting)
        .accessibilityLabel("More")
    }

    private var moreMenuOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { showMoreMenu = false }

            VStack(alignment: .leading, spacing: 0) {
                if let url = recipe?.sourceURL {
                    menuRow(systemImage: "arrow.up.right.square", title: "Original post", destructive: false) {
                        showMoreMenu = false
                        openURL(url)
                    }
                }
                menuRow(systemImage: "pencil", title: "Edit recipe", destructive: false) {
                    showMoreMenu = false
                    showEdit = true
                }
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                menuRow(systemImage: "trash", title: "Delete recipe", destructive: true) {
                    showMoreMenu = false
                    showDeleteConfirm = true
                }
            }
            .padding(6)
            .frame(minWidth: 190, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .themeShadow(Theme.shadowLG)
            .padding(.trailing, Theme.screenPadding)
            .padding(.top, 52)
        }
    }

    private func menuRow(
        systemImage: String,
        title: String,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 17)
                Text(title)
                    .font(Theme.body(14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Theme.accent800 : Theme.neutral900)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private var deleteConfirmOverlay: some View {
        ZStack {
            Theme.neutral900.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { showDeleteConfirm = false }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete this recipe?")
                        .font(Theme.display(20))
                        .foregroundStyle(Theme.ink)
                    Text("This removes it from your box. This can't be undone.")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.neutral700)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        showDeleteConfirm = false
                    }
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.neutral800)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.surface)
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)

                    Button(deleting ? "Deleting…" : "Delete") {
                        guard let recipe, !deleting else { return }
                        Task { await delete(recipe) }
                    }
                    .font(Theme.body(14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .buttonStyle(DestructiveFillButtonStyle())
                    .disabled(deleting)
                }
            }
            .padding(EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
            .frame(maxWidth: 320)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 30)
        }
    }

    private func delete(_ recipe: Recipe) async {
        deleting = true
        defer { deleting = false }
        if let error = await store.deleteRecipe(recipe) {
            deleteError = error
        } else {
            showDeleteConfirm = false
            dismiss()
        }
    }

    private func content(for recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(for: recipe)
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.top, 8)

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

    private var cookButton: some View {
        Button {
            showCookMode = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start cooking")
            }
            .font(Theme.display(16))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .themeShadow(Theme.shadowSM)
        }
        .buttonStyle(AccentFillButtonStyle())
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

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? Theme.accent100 : Color.clear)
            )
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

                        toBuyButton(for: parsed)
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
    /// to-buy list. Prefills qty from the ingredient's quantity chip.
    private func toBuyButton(for line: IngredientLine) -> some View {
        let inList = pantry.isInToBuy(line.text)
        return Button {
            pantry.toggleToBuy(text: line.text, qty: line.quantity ?? "")
        } label: {
            Image(systemName: inList ? "checkmark" : "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(inList ? Theme.bg : Theme.neutral700)
                .frame(width: 30, height: 30)
                .background(inList ? Theme.sage500 : Theme.neutral100)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inList ? "Remove \(line.text) from to-buy list" : "Add \(line.text) to to-buy list")
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
