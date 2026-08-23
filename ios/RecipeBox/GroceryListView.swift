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
                            Text(recipe.title)
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

                ForEach(groupedIngredients, id: \.key) { group in
                    Section(group.key.capitalized) {
                        ForEach(group.lines, id: \.self) { line in
                            Button {
                                toggle(line)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: checked.contains(line) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(checked.contains(line) ? Theme.accent : Theme.inkSoft)
                                    Text(line)
                                        .strikethrough(checked.contains(line))
                                        .foregroundStyle(checked.contains(line) ? Theme.inkSoft : Theme.ink)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button("Clear plan", role: .destructive) {
                        for recipe in planned { store.togglePlan(recipe) }
                        checked.removeAll()
                    }
                }
            }
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
    private var groupedIngredients: [(key: String, lines: [String])] {
        var buckets: [String: [String]] = [:]
        var seenLines: Set<String> = []
        for recipe in planned {
            for line in recipe.ingredients {
                guard seenLines.insert(line).inserted else { continue }
                buckets[canonicalKey(for: line, pantry: recipe.pantry), default: []].append(line)
            }
        }
        return buckets
            .map { (key: $0.key, lines: $0.value.sorted()) }
            .sorted { $0.key < $1.key }
    }

    private func canonicalKey(for line: String, pantry: [String]) -> String {
        let lower = line.lowercased()
        let matches = pantry.filter { lower.contains($0) }
        return matches.max(by: { $0.count < $1.count }) ?? "other"
    }
}
