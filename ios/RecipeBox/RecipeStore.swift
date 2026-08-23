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
    @Published var favoritesOnly = false {
        didSet { if oldValue != favoritesOnly { updateVisible() } }
    }
    @Published var sortOption: SortOption = .recent {
        didSet { if oldValue != sortOption { updateVisible() } }
    }
    @Published var pantryGroups: [PantryGroup] = []

    /// Transient error from a favorite toggle or edit save — separate from
    /// errorMessage, which is reserved for "couldn't load the list at all".
    @Published var actionError: String?
    /// Set by RecipeBoxApp's onOpenURL; consumed once by RootView.
    @Published var pendingRoute: DeepLinkRoute?

    @Published var planIDs: Set<Int> {
        didSet { UserDefaults.standard.set(Array(planIDs), forKey: Self.planKey) }
    }

    @Published private(set) var visibleRecipes: [Recipe] = []
    @Published private(set) var matchesByID: [Int: RecipeMatch] = [:]
    @Published private(set) var cuisines: [String] = []
    @Published private(set) var selectedPantryGroups: [PantryGroup] = []
    @Published private(set) var visiblePantryGroups: [PantryGroup] = []
    @Published private(set) var haveSet: Set<String> = []

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    /// Only needed to favorite/edit from the phone — sent as X-Recipe-Box-Key.
    /// Blank is fine against a dev server with no RECIPE_BOX_SECRET set.
    @Published var serverSecret: String {
        didSet { UserDefaults.standard.set(serverSecret, forKey: Self.secretKey) }
    }

    static let hostedURL = "https://kaihkashan-recipe-box.vercel.app"

    private static let urlKey = "recipeBox.serverURL"
    private static let secretKey = "recipeBox.serverSecret"
    private static let planKey = "recipeBox.planIDs"
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
        serverSecret = UserDefaults.standard.string(forKey: Self.secretKey) ?? ""
        planIDs = Set(UserDefaults.standard.array(forKey: Self.planKey) as? [Int] ?? [])
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

    /// Optimistic, like toggleFavorite: flips locally (so the badge/UI is
    /// instant) then pushes the whole set to the server so the plan matches
    /// on every device. Reverts on failure.
    func togglePlan(_ recipe: Recipe) {
        let previous = planIDs
        if planIDs.contains(recipe.id) {
            planIDs.remove(recipe.id)
        } else {
            planIDs.insert(recipe.id)
        }
        let updated = planIDs
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updatePlan(ids: Array(updated), secret: serverSecret)
                if planIDs == updated {
                    planIDs = Set(confirmed)
                }
            } catch {
                if planIDs == updated {
                    planIDs = previous
                }
                actionError = error.localizedDescription
            }
        }
    }

    /// One request for the whole clear, rather than N concurrent togglePlan
    /// calls racing each other to write the last (possibly stale) state.
    func clearPlan() {
        let previous = planIDs
        planIDs = []
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updatePlan(ids: [], secret: serverSecret)
                planIDs = Set(confirmed)
            } catch {
                planIDs = previous
                actionError = error.localizedDescription
            }
        }
    }

    /// Pulls the latest plan from the server — called after each refresh so
    /// a change made on another device shows up here too.
    private func syncPlanFromServer() async {
        guard let ids = try? await APIClient(baseURLString: serverURL).fetchPlan() else { return }
        planIDs = Set(ids)
    }

    var plannedRecipes: [Recipe] {
        recipes.filter { planIDs.contains($0.id) }
    }

    /// Optimistic: flips the star immediately, then confirms with the server.
    /// Reverts and surfaces actionError if the request fails.
    func toggleFavorite(_ recipe: Recipe) async {
        let optimistic = recipe.withFavorite(!recipe.favorite)
        replace(optimistic)
        do {
            let saved = try await APIClient(baseURLString: serverURL).updateRecipe(
                id: recipe.id,
                patch: RecipePatch(favorite: optimistic.favorite),
                secret: serverSecret
            )
            replace(saved)
        } catch {
            replace(recipe)
            actionError = error.localizedDescription
        }
    }

    /// Returns an error message on failure, nil on success. Not optimistic —
    /// there's no local id to assign until the server hands back the row
    /// number, so the new recipe only appears once it's actually saved.
    func addRecipe(_ draft: RecipeCreate) async -> String? {
        do {
            let created = try await APIClient(baseURLString: serverURL).createRecipe(draft, secret: serverSecret)
            recipesByID[created.id] = created
            recipes.insert(created, at: 0)
            updateDerived()
            persistCache()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message on failure, nil on success.
    func saveEdits(id: Int, title: String, servings: String?, ingredients: [String], steps: [String], notes: String) async -> String? {
        let patch = RecipePatch(title: title, servings: servings, ingredients: ingredients, steps: steps, notes: notes)
        do {
            let saved = try await APIClient(baseURLString: serverURL).updateRecipe(id: id, patch: patch, secret: serverSecret)
            replace(saved)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message on failure, nil on success. A real Gemini
    /// call server-side, so this can take a few seconds.
    func recategorizeRecipe(_ recipe: Recipe) async -> String? {
        do {
            let saved = try await APIClient(baseURLString: serverURL).recategorize(id: recipe.id, secret: serverSecret)
            replace(saved)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message on failure, nil on success. Not optimistic —
    /// deletion is destructive enough that it's worth waiting for the server
    /// to confirm before the row disappears from the list.
    func deleteRecipe(_ recipe: Recipe) async -> String? {
        do {
            try await APIClient(baseURLString: serverURL).deleteRecipe(id: recipe.id, secret: serverSecret)
            recipesByID.removeValue(forKey: recipe.id)
            recipes.removeAll { $0.id == recipe.id }
            if planIDs.remove(recipe.id) != nil {
                _ = try? await APIClient(baseURLString: serverURL).updatePlan(ids: Array(planIDs), secret: serverSecret)
            }
            updateDerived()
            persistCache()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func replace(_ updated: Recipe) {
        guard recipesByID[updated.id] != nil else { return }
        recipesByID[updated.id] = updated
        if let index = recipes.firstIndex(where: { $0.id == updated.id }) {
            recipes[index] = updated
        }
        updateDerived()
        persistCache()
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
            await syncPlanFromServer()
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
            if favoritesOnly, !recipe.favorite { return false }
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
        } else {
            switch sortOption {
            case .recent:
                break // recipes already arrive newest-first from the server
            case .az:
                rows.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case .za:
                rows.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
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
