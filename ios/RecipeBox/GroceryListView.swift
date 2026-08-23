import SwiftUI

/// The meal plan: recipes you've picked for the week, plus a flattened
/// shopping checklist. No quantity math (merging "2 cups rice" + "1 cup
/// rice" needs real unit parsing the saved data doesn't support cleanly) —
/// instead ingredient lines are grouped by pantry name so near-duplicates
/// cluster together, and you check them off as you shop.
struct GroceryListView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var checked: Set<String> = []

    private var planned: [Recipe] { store.plannedRecipes }

    var body: some View {
        List {
            if planned.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No recipes planned yet")
                            .font(.headline)
                        Text("Swipe a recipe left in the list and tap the cart to add it here.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section("Planned") {
                    ForEach(planned) { recipe in
                        NavigationLink(value: recipe.id) {
                            HStack(spacing: 12) {
                                RecipeThumb(recipe: recipe, size: 40)
                                Text(recipe.title)
                                    .font(Theme.display(15.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.togglePlan(recipe)
                            } label: {
                                Label("Remove", systemImage: "cart.badge.minus")
                            }
                        }
                    }
                }

                if omittedHaveCount > 0 {
                    Text("Grocery list · \(omittedHaveCount) item\(omittedHaveCount == 1 ? "" : "s") skipped because you already have \(omittedHaveCount == 1 ? "it" : "them")")
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .listRowSeparator(.hidden)
                }

                ForEach(groupedIngredients, id: \.key) { group in
                    Section(group.key.capitalized) {
                        ForEach(group.lines, id: \.self) { line in
                            let parsed = splitIngredientQuantity(line)
                            let isChecked = checked.contains(line)
                            Button {
                                toggle(line)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isChecked ? Theme.accent : Theme.inkSoft)
                                    if let quantity = parsed.quantity {
                                        Text(quantity)
                                            .font(Theme.mono(11.5, weight: .semibold))
                                            .foregroundStyle(isChecked ? Theme.inkSoft : Theme.accent)
                                            .strikethrough(isChecked)
                                    }
                                    Text(parsed.text)
                                        .strikethrough(isChecked)
                                        .foregroundStyle(isChecked ? Theme.inkSoft : Theme.ink)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !alsoMakeable.isEmpty {
                    Section {
                        ForEach(alsoMakeable) { recipe in
                            NavigationLink(value: recipe.id) {
                                Text(recipe.title)
                                    .font(Theme.display(15, weight: .semibold))
                            }
                        }
                    } header: {
                        Text("You could also make")
                    } footer: {
                        Text("Fully covered by what you have plus everything on this shopping list.")
                    }
                }

                Section {
                    Button("Clear plan", role: .destructive) {
                        store.clearPlan()
                        checked.removeAll()
                    }
                }
            }

            Color.clear
                .frame(height: 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Int.self) { id in
            RecipeDetailView(id: id)
        }
    }

    private func toggle(_ line: String) {
        if checked.contains(line) {
            checked.remove(line)
        } else {
            checked.insert(line)
        }
    }

    /// Ingredient lines from every planned recipe, grouped by whichever of
    /// the recipe's already-canonicalized pantry names (server-computed —
    /// see app/match.py) the line mentions, so "2 cups basmati rice" and
    /// "1 cup rice" both land under "rice" without re-parsing quantities.
    /// Skips anything already in "what I have" — this is a shopping list,
    /// not a full ingredient list.
    private var groupedIngredients: [(key: String, lines: [String])] {
        var buckets: [String: [String]] = [:]
        var seenLines: Set<String> = []
        for recipe in planned {
            for line in recipe.ingredients {
                guard seenLines.insert(line).inserted else { continue }
                let key = canonicalKey(for: line, pantry: recipe.pantry)
                guard !store.haveSet.contains(where: { namesMatch($0, key) }) else { continue }
                buckets[key, default: []].append(line)
            }
        }
        return buckets
            .map { (key: $0.key, lines: $0.value.sorted()) }
            .sorted { $0.key < $1.key }
    }

    /// How many distinct ingredient lines were left off the list above
    /// because they matched something in "what I have".
    private var omittedHaveCount: Int {
        var seenLines: Set<String> = []
        var count = 0
        for recipe in planned {
            for line in recipe.ingredients {
                guard seenLines.insert(line).inserted else { continue }
                let key = canonicalKey(for: line, pantry: recipe.pantry)
                if store.haveSet.contains(where: { namesMatch($0, key) }) { count += 1 }
            }
        }
        return count
    }

    /// Recipes outside the plan that would become fully makeable once you've
    /// done this shopping — "what I have" plus every ingredient already
    /// needed for the planned recipes.
    private var alsoMakeable: [Recipe] {
        let plannedIDs = Set(planned.map(\.id))
        guard !plannedIDs.isEmpty else { return [] }
        let expanded = store.haveSet.union(planned.flatMap(\.pantry))
        return store.recipes
            .filter { !plannedIDs.contains($0.id) && isFullyCovered($0, by: expanded) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func canonicalKey(for line: String, pantry: [String]) -> String {
        let lower = line.lowercased()
        let matches = pantry.filter { lower.contains($0) }
        return matches.max(by: { $0.count < $1.count }) ?? "other"
    }
}
