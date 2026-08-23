import Foundation

@MainActor
final class RecipeStore: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var mealFilter = "all" {
        didSet { if oldValue != mealFilter { updateVisible() } }
    }
    @Published var cuisineFilter = "all" {
        didSet { if oldValue != cuisineFilter { updateVisible() } }
    }
    @Published var query = "" {
        didSet { if oldValue != query { updateVisible() } }
    }
    @Published var have: [String] = [] {
        didSet { if oldValue != have { updateVisible() } }
    }
    @Published var pantryGroups: [PantryGroup] = []

    @Published private(set) var visibleRecipes: [Recipe] = []
    @Published private(set) var matchesByID: [Int: RecipeMatch] = [:]
    @Published private(set) var cuisines: [String] = []
    @Published private(set) var selectedPantryGroups: [PantryGroup] = []
    @Published private(set) var visiblePantryGroups: [PantryGroup] = []
    @Published private(set) var haveSet: Set<String> = []

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    static let hostedURL = "https://kaihkashan-recipe-box.vercel.app"

    private static let urlKey = "recipeBox.serverURL"
    private static let legacyLANDefault = "http://192.168.0.54:8000"
    private static let legacyHostedHosts: Set<String> = [
        "recipe-box-ashen-alpha.vercel.app",
    ]
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private var recipesByID: [Int: Recipe] = [:]
    private var refreshTask: Task<Bool, Never>?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        let resolved = Self.resolvedURL(from: stored)
        serverURL = resolved
        UserDefaults.standard.set(resolved, forKey: Self.urlKey)
        loadCache()
    }

    /// Prefer the hosted backend. Old LAN defaults still stored on the phone
    /// would otherwise keep requiring the Mac to be awake.
    private static func resolvedURL(from stored: String) -> String {
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == legacyLANDefault { return hostedURL }
        guard let host = URL(string: value)?.host?.lowercased() else { return hostedURL }
        if legacyHostedHosts.contains(host) { return hostedURL }
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

    func recipe(id: Int) -> Recipe? {
        recipesByID[id]
    }

    func toggleIngredient(_ item: String) {
        if let index = have.firstIndex(of: item) {
            have.remove(at: index)
        } else {
            have.append(item)
            if !query.isEmpty {
                query = ""
            }
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        refreshTask?.cancel()
        let task = Task { await loadRemote() }
        refreshTask = task
        return await task.value
    }

    private func loadRemote() async -> Bool {
        let hadRecipes = !recipes.isEmpty
        if !hadRecipes {
            isLoading = true
        }
        defer { isLoading = false }

        do {
            let payload = try await APIClient(baseURLString: serverURL).fetchRecipes()
            guard !Task.isCancelled else { return false }
            apply(recipes: payload.recipes, pantry: payload.pantry)
            errorMessage = nil
            persistCache()
            prefetchThumbnails()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            if !hadRecipes {
                recipes = []
                pantryGroups = []
                recipesByID = [:]
                errorMessage = error.localizedDescription
                updateDerived()
            }
            return false
        }
    }

    private func apply(recipes: [Recipe], pantry: [PantryGroup]) {
        self.recipes = recipes
        pantryGroups = pantry.map { PantryGroup(category: $0.category, items: collapsePantryItems($0.items)) }
        recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        updateDerived()
    }

    private func updateVisible() {
        haveSet = Set(have)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = recipes.filter { recipe in
            if mealFilter != "all", recipe.meal != mealFilter { return false }
            if cuisineFilter != "all", recipe.cuisine != cuisineFilter { return false }
            if needle.isEmpty { return true }
            return recipe.searchBlob.contains(needle)
        }

        var matches: [Int: RecipeMatch] = [:]
        if !have.isEmpty {
            rows = rows.compactMap { recipe in
                guard let match = matchRecipe(recipe, have: have) else { return nil }
                matches[recipe.id] = match
                return recipe
            }
            rows.sort { lhs, rhs in
                let left = matches[lhs.id]!
                let right = matches[rhs.id]!
                if left.score != right.score { return left.score > right.score }
                return left.extraCount < right.extraCount
            }
        }
        visibleRecipes = rows
        matchesByID = matches
        updatePantry()
    }

    private func updatePantry() {
        haveSet = Set(have)
        let groups = resolvedPantryGroups
        selectedPantryGroups = groups.compactMap { group in
            let items = group.items.filter { haveSet.contains($0) }
            return items.isEmpty ? nil : PantryGroup(category: group.category, items: items)
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            visiblePantryGroups = []
            return
        }
        visiblePantryGroups = groups.compactMap { group in
            let items = group.items.filter { item in
                !haveSet.contains(item) && (item.contains(needle) || needle.contains(item) || namesMatch(item, needle))
            }
            return items.isEmpty ? nil : PantryGroup(category: group.category, items: items)
        }
    }

    private func updateDerived() {
        cuisines = Array(Set(recipes.map(\.cuisine).filter { !$0.isEmpty })).sorted()
        updateVisible()
    }

    private var resolvedPantryGroups: [PantryGroup] {
        if !pantryGroups.isEmpty { return pantryGroups }
        let items = Array(
            Set(
                recipes.flatMap(\.pantry).filter { !["salt", "water", "oil", "pepper", "black pepper", "sugar"].contains($0) }
            )
        ).sorted()
        return items.isEmpty ? [] : [PantryGroup(category: "Ingredients", items: items)]
    }

    private func prefetchThumbnails() {
        let urls = recipes.prefix(30).compactMap(\.thumbnailURL)
        Task.detached(priority: .utility) {
            for url in urls {
                _ = await ThumbnailCache.shared.image(for: url, maxPixel: 168)
            }
        }
    }

    private func cacheURL() -> URL? {
        let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return folder?.appendingPathComponent("recipe-box-cache.json")
    }

    private func loadCache() {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(RecipeCache.self, from: data),
              payload.serverURL == serverURL
        else { return }
        apply(recipes: payload.recipes, pantry: payload.pantry)
    }

    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = RecipeCache(serverURL: serverURL, recipes: recipes, pantry: pantryGroups)
        guard let data = try? Self.encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct RecipeCache: Codable {
    let serverURL: String
    let recipes: [Recipe]
    let pantry: [PantryGroup]
}
