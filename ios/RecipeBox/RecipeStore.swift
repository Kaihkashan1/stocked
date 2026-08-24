import Foundation

@MainActor
final class RecipeStore: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Tags cover cooking method/appliance (air-fryer, one-pot, ...) as well
    /// as diet/flavor — whatever Gemini tagged the recipe with — so this is
    /// the one filter dimension that covers something like "Air Fryer"
    /// without a hardcoded category list.
    @Published var tagFilter = "all" {
        didSet { if oldValue != tagFilter { updateVisible() } }
    }
    @Published var query = "" {
        didSet { if oldValue != query { updateVisible() } }
    }
    /// The pantry — ingredients you currently have on hand. Synced across
    /// devices via /api/pantry, same as the shopping list, so it's a real
    /// inventory rather than a per-session browsing filter.
    @Published var have: [String] = [] {
        didSet {
            if oldValue != have {
                UserDefaults.standard.set(have, forKey: Self.haveKey)
                updateVisible()
            }
        }
    }
    /// Search box on the Pantry tab, separate from the recipe list's
    /// `query` — filters the browsable catalog, not the recipe list.
    @Published var pantryQuery = "" {
        didSet { if oldValue != pantryQuery { updatePantry() } }
    }
    @Published var favoritesOnly = false {
        didSet { if oldValue != favoritesOnly { updateVisible() } }
    }
    /// SuperCook-style hard filter: when on, only recipes fully covered by
    /// `have` show at all. Off by default — the score-sorted "closest fit"
    /// view stays the default the same way it always has.
    @Published var onlyMakeable = false {
        didSet { if oldValue != onlyMakeable { updateVisible() } }
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

    /// Ingredients the user intends to buy but hasn't yet — distinct from
    /// "have" (already possess). Synced across devices, same pattern as the
    /// pantry.
    @Published var shoppingList: Set<String> {
        didSet { UserDefaults.standard.set(Array(shoppingList), forKey: Self.shoppingListKey) }
    }

    @Published private(set) var visibleRecipes: [Recipe] = []
    @Published private(set) var matchesByID: [Int: RecipeMatch] = [:]
    @Published private(set) var cuisines: [String] = []
    @Published private(set) var tags: [String] = []
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
    private static let haveKey = "recipeBox.have"
    private static let shoppingListKey = "recipeBox.shoppingList"
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
        have = UserDefaults.standard.array(forKey: Self.haveKey) as? [String] ?? []
        shoppingList = Set(UserDefaults.standard.array(forKey: Self.shoppingListKey) as? [String] ?? [])
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

    /// Optimistic, same shape as toggleShoppingItem: flips locally (so the
    /// UI is instant) then pushes the whole pantry to the server so it
    /// matches on every device. Reverts on failure.
    func toggleIngredient(_ item: String) {
        let previous = have
        if let index = have.firstIndex(of: item) {
            have.remove(at: index)
        } else {
            have.append(item)
            if !pantryQuery.isEmpty {
                pantryQuery = ""
            }
        }
        let updated = have
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updatePantry(items: updated, secret: serverSecret)
                if have == updated {
                    have = confirmed
                }
            } catch {
                if have == updated {
                    have = previous
                }
                actionError = error.localizedDescription
            }
        }
    }

    /// A free-text addition — for something you have that isn't derived from
    /// any recipe (a specific brand, a leftover, whatever). Normalized like
    /// the server does (trimmed, lowercased) so it still matches recipe
    /// ingredients via namesMatch just like a catalog pick would.
    func addHaveItem(_ raw: String) {
        let item = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !item.isEmpty, !have.contains(where: { $0 == item || namesMatch($0, item) }) else { return }
        // The server re-categorizes on the next full reload; this just keeps
        // a freshly-typed custom item from vanishing from "What I have" (or
        // being unfindable in the catalog) until then.
        if !pantryGroups.contains(where: { $0.items.contains(item) }) {
            if let index = pantryGroups.firstIndex(where: { $0.category == "Other" }) {
                var items = pantryGroups[index].items
                items.append(item)
                pantryGroups[index] = PantryGroup(category: "Other", items: items.sorted())
            } else {
                pantryGroups.append(PantryGroup(category: "Other", items: [item]))
            }
        }
        toggleIngredient(item)
    }

    /// Bulk replace, for the recipebox://have deep link (e.g. a Shortcuts
    /// pantry scan) — one request for the whole set rather than N toggles.
    func setHave(_ items: [String]) {
        let previous = have
        have = items
        let updated = items
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updatePantry(items: updated, secret: serverSecret)
                if have == updated {
                    have = confirmed
                }
            } catch {
                if have == updated {
                    have = previous
                }
                actionError = error.localizedDescription
            }
        }
    }

    /// Pulls the latest pantry from the server — called after each refresh
    /// so a change made on another device shows up here too.
    private func syncPantryFromServer() async {
        guard let items = try? await APIClient(baseURLString: serverURL).fetchPantry() else { return }
        have = items
    }

    private func syncShoppingListFromServer() async {
        guard let items = try? await APIClient(baseURLString: serverURL).fetchShoppingList() else { return }
        shoppingList = Set(items)
    }

    /// Optimistic, same shape as toggleIngredient.
    func toggleShoppingItem(_ item: String) {
        let previous = shoppingList
        if shoppingList.contains(item) {
            shoppingList.remove(item)
        } else {
            shoppingList.insert(item)
        }
        let updated = shoppingList
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updateShoppingList(items: Array(updated), secret: serverSecret)
                if shoppingList == updated {
                    shoppingList = Set(confirmed)
                }
            } catch {
                if shoppingList == updated {
                    shoppingList = previous
                }
                actionError = error.localizedDescription
            }
        }
    }

    /// Bulk version of toggleShoppingItem, for the recipe detail view's "add
    /// missing to shopping list" button — one request for the whole gap
    /// rather than N toggles racing to write the last (possibly stale) state.
    func addToShoppingList(_ items: [String]) {
        guard !items.isEmpty else { return }
        let previous = shoppingList
        shoppingList.formUnion(items)
        let updated = shoppingList
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL).updateShoppingList(items: Array(updated), secret: serverSecret)
                if shoppingList == updated {
                    shoppingList = Set(confirmed)
                }
            } catch {
                if shoppingList == updated {
                    shoppingList = previous
                }
                actionError = error.localizedDescription
            }
        }
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

    /// Returns the extraction on success, or an error message on failure.
    /// Doesn't touch `recipes` — nothing is saved until the user reviews the
    /// pre-filled Add Recipe form and taps Save.
    func extractRecipePhoto(_ imageData: Data) async -> (RecipeExtraction?, String?) {
        do {
            let extraction = try await APIClient(baseURLString: serverURL).extractPhoto(imageData: imageData, secret: serverSecret)
            return (extraction, nil)
        } catch {
            return (nil, error.localizedDescription)
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

    /// Returns an error message on failure, nil on success. Not optimistic —
    /// deletion is destructive enough that it's worth waiting for the server
    /// to confirm before the row disappears from the list.
    func deleteRecipe(_ recipe: Recipe) async -> String? {
        do {
            try await APIClient(baseURLString: serverURL).deleteRecipe(id: recipe.id, secret: serverSecret)
            recipesByID.removeValue(forKey: recipe.id)
            recipes.removeAll { $0.id == recipe.id }
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
            await syncPantryFromServer()
            await syncShoppingListFromServer()
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
            if tagFilter != "all", !recipe.tags.contains(tagFilter) { return false }
            if needle.isEmpty { return true }
            return recipe.searchBlob.contains(needle)
        }

        // Unlike the old ingredient-search behavior, marking more pantry
        // items never hides a recipe on its own — matchRecipe always
        // returns a score/missing count once `have` is non-empty. The only
        // hard filter is the explicit "only what I can make" toggle.
        var matches: [Int: RecipeMatch] = [:]
        if !have.isEmpty {
            for recipe in rows {
                matches[recipe.id] = matchRecipe(recipe, have: have)
            }
            if onlyMakeable {
                rows = rows.filter { matches[$0.id]?.fullyCovered == true }
            }
            rows.sort { lhs, rhs in
                let left = matches[lhs.id]!
                let right = matches[rhs.id]!
                if left.score != right.score { return left.score > right.score }
                return left.missingCount < right.missingCount
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

        // Gated behind actually typing something — as the recipe box grows,
        // the full catalog is too long to skim, so this is a search box,
        // not a browsable list.
        let needle = pantryQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        tags = Array(Set(recipes.flatMap(\.tags))).sorted()
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
