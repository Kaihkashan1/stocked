import Foundation

@MainActor
final class RecipeStore: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var mealFilter = "all"
    @Published var cuisineFilter = "all"
    @Published var query = ""
    @Published var have: [String] = []
    @Published var pantryQuery = ""
    @Published var pantryGroups: [PantryGroup] = []

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    private static let urlKey = "recipeBox.serverURL"
    private static let defaultURL = "http://192.168.0.54:8000"

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
    }

    var cuisines: [String] {
        Array(Set(recipes.map(\.cuisine).filter { !$0.isEmpty })).sorted()
    }

    var pantryItems: [String] {
        Array(Set(recipes.flatMap(\.pantry).filter { !["salt", "water", "oil", "pepper", "black pepper", "sugar"].contains($0) })).sorted()
    }

    private var resolvedPantryGroups: [PantryGroup] {
        if !pantryGroups.isEmpty { return pantryGroups }
        let items = pantryItems
        return items.isEmpty ? [] : [PantryGroup(category: "Ingredients", items: items)]
    }

    var selectedPantryGroups: [PantryGroup] {
        resolvedPantryGroups.compactMap { group in
            let items = group.items.filter { have.contains($0) }
            return items.isEmpty ? nil : PantryGroup(category: group.category, items: items)
        }
    }

    var visiblePantryGroups: [PantryGroup] {
        let needle = pantryQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return resolvedPantryGroups.compactMap { group in
            let items = group.items.filter { item in
                !have.contains(item) && (needle.isEmpty || item.contains(needle) || needle.contains(item) || namesMatch(item, needle))
            }
            return items.isEmpty ? nil : PantryGroup(category: group.category, items: items)
        }
    }

    var visibleRecipes: [Recipe] {
        var rows = recipes.filter { recipe in
            if mealFilter != "all", recipe.meal != mealFilter { return false }
            if cuisineFilter != "all", recipe.cuisine != cuisineFilter { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if needle.isEmpty { return true }
            let haystack = (
                [recipe.title, recipe.cuisine, recipe.meal]
                    + recipe.tags
                    + recipe.ingredients
            ).joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
        if !have.isEmpty {
            rows = rows.filter { matchRecipe($0, have: have) != nil }
            rows.sort { lhs, rhs in
                let left = matchRecipe(lhs, have: have)!
                let right = matchRecipe(rhs, have: have)!
                if left.score != right.score { return left.score > right.score }
                return left.extraCount < right.extraCount
            }
        }
        return rows
    }

    func toggleIngredient(_ item: String) {
        if let index = have.firstIndex(of: item) {
            have.remove(at: index)
        } else {
            have.append(item)
        }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let payload = try await APIClient(baseURLString: serverURL).fetchRecipes()
            recipes = payload.recipes
            pantryGroups = payload.pantry
        } catch {
            recipes = []
            pantryGroups = []
            errorMessage = error.localizedDescription
        }
    }
}
