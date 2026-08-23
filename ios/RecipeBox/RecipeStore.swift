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

    static let hostedURL = "https://recipe-box-ashen-alpha.vercel.app"

    private static let urlKey = "recipeBox.serverURL"
    private static let legacyLANDefault = "http://192.168.0.54:8000"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        let resolved = Self.resolvedURL(from: stored)
        serverURL = resolved
        UserDefaults.standard.set(resolved, forKey: Self.urlKey)
    }

    /// Prefer the hosted backend. Old LAN defaults still stored on the phone
    /// would otherwise keep requiring the Mac to be awake.
    private static func resolvedURL(from stored: String) -> String {
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == legacyLANDefault { return hostedURL }
        guard let host = URL(string: value)?.host?.lowercased() else { return hostedURL }
        if host == "localhost" || host == "127.0.0.1" { return hostedURL }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return hostedURL }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) {
                return hostedURL
            }
        }
        return value
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
