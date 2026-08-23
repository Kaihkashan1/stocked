import SwiftUI

struct RecipeDetailView: View {
    let id: Int
    @EnvironmentObject private var store: RecipeStore
    @State private var showEdit = false

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
        .toolbar {
            if let recipe {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.toggleFavorite(recipe) }
                    } label: {
                        Image(systemName: recipe.favorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(recipe.favorite ? "Remove from favorites" : "Add to favorites")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEdit = true }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let recipe {
                EditRecipeView(recipe: recipe)
                    .environmentObject(store)
            }
        }
    }

    private func content(for recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(for: recipe)
                if !recipe.tags.isEmpty {
                    tags(for: recipe)
                }
                if !recipe.ingredients.isEmpty {
                    section(title: "Ingredients") {
                        ForEach(recipe.ingredients, id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                Text(item)
                            }
                        }
                    }
                }
                if !recipe.steps.isEmpty {
                    section(title: "Steps") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1).")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 24, alignment: .trailing)
                                Text(step)
                            }
                        }
                    }
                }
                if let url = recipe.sourceURL {
                    Link("Original post", destination: url)
                        .font(.body.weight(.medium))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RecipeThumb(recipe: recipe, size: 88)
            Text(recipe.title)
                .font(.title.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(metaLine(for: recipe))
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
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
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.bg)
                    .foregroundStyle(Theme.accent)
                    .clipShape(Capsule())
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
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
