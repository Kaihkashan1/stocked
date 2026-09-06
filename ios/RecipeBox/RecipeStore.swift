import Foundation
import Observation

/// @Observable rather than ObservableObject on purpose: with objectWillChange,
/// every view holding the store re-rendered on every change, so one keystroke
/// in the search box invalidated the whole list screen. The macro tracks reads
/// per property per view body instead, so a change to `query` only re-runs the
/// bodies that actually read `query`. Its generated setters also skip
/// notification when an Equatable value is assigned its current value, which
/// matters here because updateVisible() rewrites all of the derived properties
/// below on every pass.
@Observable
@MainActor
final class RecipeStore {
    var recipes: [Recipe] = []
    var isLoading = false
    var errorMessage: String?
    /// Tags cover cooking method/appliance (air-fryer, one-pot, ...), diet
    /// (vegetarian, non-vegetarian), course (dessert), and source (mom's
    /// recipes) — whatever a recipe is tagged with — so this is the one
    /// filter dimension that covers any category without a hardcoded list.
    /// Multi-select (AND): a recipe must carry every selected tag.
    var tagFilters: Set<String> = [] {
        didSet { if oldValue != tagFilters { updateVisible() } }
    }
    /// The course filter row on the list screen — Main course / Appetizers /
    /// Desserts / Dips. nil means no course filter is applied. Composes with every
    /// other filter (AND), same as tagFilters.
    var courseFilter: Course? {
        didSet { if oldValue != courseFilter { updateVisible() } }
    }
    /// Filters' Source chip row (Instagram/YouTube/TikTok/Link/Photo/Typed
    /// in). Multi-select, but OR'd together rather than AND'd like
    /// tagFilters — a recipe only ever has one source, so requiring all
    /// selected sources at once would just show nothing past the first pick.
    var sourceFilters: Set<SourceCategory> = [] {
        didSet { if oldValue != sourceFilters { updateVisible() } }
    }
    var query = "" {
        didSet { if oldValue != query { updateVisible() } }
    }
    /// Ingredient filters for the Recipes list — not inventory. Synced via
    /// /api/pantry as a flat string list. The Pantry tab's stock lives in
    /// PantryStore (/api/pantry-inventory) and is a separate concept.
    var have: [String] = [] {
        didSet {
            if oldValue != have {
                UserDefaults.standard.set(have, forKey: Self.haveKey)
                updateVisible()
            }
        }
    }
    var favoritesOnly = false {
        didSet { if oldValue != favoritesOnly { updateVisible() } }
    }
    var sortOption: SortOption = .recent {
        didSet { if oldValue != sortOption { updateVisible() } }
    }
    /// The list screen's grid/list toggle — a per-device display
    /// preference, not app data, so it's local-only rather than synced.
    var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey) }
    }
    var pantryGroups: [PantryGroup] = []

    /// Transient error from a favorite toggle or edit save — separate from
    /// errorMessage, which is reserved for "couldn't load the list at all".
    var actionError: String?
    /// Set by RecipeBoxApp's onOpenURL; consumed once by RootView.
    var pendingRoute: DeepLinkRoute?
    /// Link and photo imports that outlive the add sheet / camera overlay.
    var importJobs: [BackgroundImportJob] = []
    /// Banners the user dismissed; a later status change (saved / error)
    /// is shown again so they still find out how it ended.
    var dismissedImportBannerIDs: Set<UUID> = []

    private(set) var visibleRecipes: [Recipe] = []
    private(set) var matchesByID: [Int: RecipeMatch] = [:]
    /// The suggested six (see recipeTags) plus whatever tags actually
    /// appear on a saved recipe. A tag typed into Add/Edit before that
    /// recipe is saved deliberately isn't in here yet — it shows up as soon
    /// as the save succeeds, via `recipes` — see TagPicker.addDraft.
    private(set) var tags: [String] = []
    private(set) var selectedPantryGroups: [PantryGroup] = []
    private(set) var visiblePantryGroups: [PantryGroup] = []
    private(set) var haveSet: Set<String> = []

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    /// Only needed to favorite/edit from the phone — sent as X-Recipe-Box-Key.
    /// Blank is fine against a dev server with no RECIPE_BOX_SECRET set.
    var serverSecret: String {
        didSet { UserDefaults.standard.set(serverSecret, forKey: Self.secretKey) }
    }

    static let hostedURL = "https://stocked-cookbook-cupboard.vercel.app"

    private static let urlKey = "recipeBox.serverURL"
    private static let secretKey = "recipeBox.serverSecret"
    private static let haveKey = "recipeBox.have"
    private static let viewModeKey = "recipeBox.viewMode"
    private static let legacyLANDefault = "http://192.168.0.54:8000"
    // nonisolated: encode/decode need to run from persistCache()'s background
    // task (see below), not hop back to the main actor just to reach these.
    // Plain JSONEncoder/JSONDecoder instances hold no actor-isolated state,
    // so sharing them across a sequential (never-concurrent) call pattern
    // like this one is safe.
    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    /// Tracked despite being private: recipe(id:) reads it, and that's what
    /// RecipeDetailView renders from. Marking it @ObservationIgnored would
    /// leave the detail screen with no observable read at all, so favoriting
    /// or editing from there would update the store without redrawing.
    private var recipesByID: [Int: Recipe] = [:]
    /// Nothing reads this, so there's no reason to pay for tracking it.
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var lastSuccessfulRefresh: Date?
    @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]
    private static let staleInterval: TimeInterval = 90

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        let resolved = Self.resolvedURL(from: stored)
        serverURL = resolved
        UserDefaults.standard.set(resolved, forKey: Self.urlKey)
        serverSecret = UserDefaults.standard.string(forKey: Self.secretKey) ?? ""
        // Ahead of `have`, whose didSet reaches back into the rest of the
        // store: the properties without a default value all have to be
        // initialized before anything here can touch self.
        viewMode = UserDefaults.standard.string(forKey: Self.viewModeKey).flatMap(ViewMode.init(rawValue:)) ?? .list
        have = UserDefaults.standard.array(forKey: Self.haveKey) as? [String] ?? []
        loadCache()
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

    func recipe(id: Int) -> Recipe? {
        recipesByID[id]
    }

    /// Sort is excluded on purpose: it reorders results but never hides any,
    /// so a non-default sort shouldn't make the screen advertise itself as
    /// filtered.
    var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tagFilters.isEmpty
            || courseFilter != nil
            || !sourceFilters.isEmpty
            || favoritesOnly
            || !have.isEmpty
    }

    /// Back to the full list in one tap. Ingredients go too — they narrow
    /// what you see just like the other filters do. Routed through setHave so
    /// the emptied list reaches the server like any other change to it.
    func clearFilters() {
        query = ""
        tagFilters = []
        courseFilter = nil
        sourceFilters = []
        favoritesOnly = false
        sortOption = .recent
        if !have.isEmpty {
            setHave([])
        }
    }

    /// Optimistic, like toggleFavorite: flips locally (so the UI is
    /// instant) then pushes the ingredient filter list to the server so it
    /// matches on every device. Reverts on failure.
    func toggleIngredient(_ item: String) {
        let previous = have
        if let index = have.firstIndex(of: item) {
            have.remove(at: index)
        } else {
            have.append(item)
            ensurePantryGroupContains(item)
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

    /// A free-text addition to the ingredient filter — for something that
    /// isn't in the catalog yet. Normalized like the server does (trimmed,
    /// lowercased) so it still matches recipe pantry stems via namesMatch.
    func addHaveItem(_ raw: String) {
        let item = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !item.isEmpty, !have.contains(where: { $0 == item || namesMatch($0, item) }) else { return }
        toggleIngredient(item)
    }

    /// True once the search box holds something that doesn't already
    /// exactly match a catalog ingredient or an existing "have" item —
    /// that's when "+ Add" is a real option rather than a no-op duplicate
    /// of just selecting an existing chip.
    func canAddTypedPantryItem(_ raw: String) -> Bool {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        let known = pantryGroups.flatMap(\.items) + have
        return !known.contains { $0.lowercased() == needle }
    }

    /// The server re-categorizes a brand-new custom item on the next full
    /// reload (and apply()'s merge carries it forward if a reload lands
    /// before that happens) — this just keeps it from being unfindable in
    /// the catalog in the meantime. Called from toggleIngredient itself, not
    /// just addHaveItem, so any path that adds something to `have` keeps
    /// this invariant.
    private func ensurePantryGroupContains(_ item: String) {
        guard !pantryGroups.contains(where: { $0.items.contains(item) }) else { return }
        if let index = pantryGroups.firstIndex(where: { $0.category == "Other" }) {
            var items = pantryGroups[index].items
            items.append(item)
            pantryGroups[index] = PantryGroup(category: "Other", items: items.sorted())
        } else {
            pantryGroups.append(PantryGroup(category: "Other", items: [item]))
        }
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

    /// For the Settings screen's "API usage" card. Not cached/published on
    /// the store like `recipes` — it's read once when Settings appears, not
    /// something the rest of the app needs to react to.
    func fetchUsage() async -> UsageStats? {
        try? await APIClient(baseURLString: serverURL).fetchUsage(secret: serverSecret)
    }

    func fetchImportLog() async -> [ImportLogEntry]? {
        try? await APIClient(baseURLString: serverURL).fetchImportLog(secret: serverSecret)
    }

    func startLinkImport(_ urlString: String) -> UUID {
        let id = UUID()
        importJobs.append(BackgroundImportJob(id: id, kind: .link(urlString), status: .running))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.ingestLink(urlString)
            self.finishImport(id: id) { job in
                switch outcome {
                case .saved(let recipe):
                    job.status = .saved(recipeID: recipe.id, title: recipe.title)
                case .error(let message):
                    job.status = .failed(message)
                }
            }
        }
        importTasks[id] = task
        return id
    }

    func startPhotoImport(_ imageData: Data) -> UUID {
        let id = UUID()
        importJobs.append(BackgroundImportJob(id: id, kind: .photo, status: .running))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let (extraction, error) = await self.extractRecipePhoto(imageData)
            self.finishImport(id: id) { job in
                if let extraction {
                    job.status = .photoReady(extraction)
                } else {
                    job.status = .failed(error ?? L("Something went wrong."))
                }
            }
        }
        importTasks[id] = task
        return id
    }

    func dismissImportBanner(id: UUID) {
        dismissedImportBannerIDs.insert(id)
        if let job = importJobs.first(where: { $0.id == id }), !job.isRunning {
            importJobs.removeAll { $0.id == id }
        }
    }

    func consumeImportJob(id: UUID) {
        importJobs.removeAll { $0.id == id }
        dismissedImportBannerIDs.remove(id)
        importTasks[id] = nil
    }

    private func finishImport(id: UUID, update: (inout BackgroundImportJob) -> Void) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        update(&importJobs[index])
        dismissedImportBannerIDs.remove(id)
        importTasks[id] = nil
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

    /// Posts a link to /ingest (same endpoint the Save Recipe Shortcut
    /// uses), then polls the recipe list for the row it produced — the
    /// endpoint itself only returns a title/URL, not a full Recipe, and the
    /// sheet write can lag slightly behind the response. "duplicate" is
    /// treated the same as "saved": either way there's a matching row to
    /// find and open.
    func ingestLink(_ urlString: String) async -> LinkIngestOutcome {
        let result: IngestResult
        do {
            result = try await APIClient(baseURLString: serverURL).ingest(url: urlString, secret: serverSecret)
        } catch {
            return .error(error.localizedDescription)
        }
        if result.status == "error" {
            return .error(result.error ?? result.message ?? L("Something went wrong."))
        }
        if let recipe = await findRecipe(afterIngest: result, fallbackURL: urlString) {
            return .saved(recipe)
        }
        return .error(L("Saved, but it hasn't shown up in your box yet — pull to refresh in a moment."))
    }

    /// Polls for the row /ingest just produced. Fetches directly via
    /// APIClient rather than calling the full refresh() (which also
    /// re-syncs the pantry from a second endpoint, re-persists the local
    /// cache, and republishes visibleRecipes/tags) on every one of up to 5
    /// attempts — this loop only needs to know when one specific recipe
    /// shows up, so the store is only actually updated once: when it's
    /// found, or on the final attempt if it never is.
    private func findRecipe(afterIngest result: IngestResult, fallbackURL: String, attempts: Int = 5) async -> Recipe? {
        let targetURL = result.url ?? fallbackURL
        let client = APIClient(baseURLString: serverURL)
        for attempt in 0..<attempts {
            let isLastAttempt = attempt == attempts - 1
            guard let payload = try? await client.fetchRecipes() else {
                if !isLastAttempt { try? await Task.sleep(for: .seconds(1.5)) }
                continue
            }
            let match = result.title.flatMap { title in payload.recipes.first { $0.title == title } }
                ?? payload.recipes.first { urlsRoughlyMatch($0.source, targetURL) }
            if match != nil || isLastAttempt {
                apply(recipes: payload.recipes, pantry: payload.pantry)
                persistCache()
            }
            if let match { return match }
            if !isLastAttempt {
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        return nil
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
    func saveEdits(id: Int, title: String, ingredients: [String], steps: [String], notes: String, tags: [String], course: Course) async -> String? {
        let patch = RecipePatch(title: title, ingredients: ingredients, steps: steps, notes: notes, tags: tags, course: course.rawValue)
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
    func refresh(force: Bool = true) async -> Bool {
        if !force, let lastSuccessfulRefresh, Date().timeIntervalSince(lastSuccessfulRefresh) < Self.staleInterval {
            return true
        }
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await loadRemote() }
        refreshTask = task
        let result = await task.value
        if refreshTask == task {
            refreshTask = nil
        }
        return result
    }

    private func loadRemote() async -> Bool {
        let hadRecipes = !recipes.isEmpty
        if !hadRecipes {
            isLoading = true
        }
        defer { isLoading = false }

        do {
            let client = APIClient(baseURLString: serverURL)
            async let catalog = client.fetchRecipes()
            async let haveItems = client.fetchPantry()
            let payload = try await catalog
            guard !Task.isCancelled else { return false }
            apply(recipes: payload.recipes, pantry: payload.pantry)
            if let items = try? await haveItems {
                have = items
            }
            errorMessage = nil
            lastSuccessfulRefresh = Date()
            persistCache()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            // Keep the on-disk catalog on screen. Writes (favorite, edit,
            // add) still need the network; browsing and cook mode do not.
            if !hadRecipes {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func apply(recipes: [Recipe], pantry: [PantryGroup]) {
        let fresh = pantry.map { PantryGroup(category: $0.category, items: collapsePantryItems($0.items)) }
        let merged = mergeCustomPantryItems(into: fresh)
        // A foreground refresh that brought back the same catalog used to
        // rewrite `recipes` and `visibleRecipes` anyway, which rebuilt the
        // whole list (and replayed card fade-ins). Skip when nothing moved.
        if self.recipes == recipes, pantryGroups == merged {
            if recipesByID.isEmpty {
                recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
            }
            return
        }
        self.recipes = recipes
        pantryGroups = merged
        recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        updateDerived()
    }

    /// A custom pantry item (typed in free-hand) might not have round-tripped
    /// to the server yet when this refresh's catalog was fetched — carry it
    /// forward instead of silently dropping it from "What I have" the moment
    /// a refresh happens to land in between.
    private func mergeCustomPantryItems(into fresh: [PantryGroup]) -> [PantryGroup] {
        let freshItems = Set(fresh.flatMap(\.items))
        let missing = have.filter { !freshItems.contains($0) }
        guard !missing.isEmpty else { return fresh }
        var merged = fresh
        if let index = merged.firstIndex(where: { $0.category == "Other" }) {
            merged[index] = PantryGroup(category: "Other", items: (merged[index].items + missing).sorted())
        } else {
            merged.append(PantryGroup(category: "Other", items: missing.sorted()))
        }
        return merged
    }

    private func updateVisible() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = recipes.filter { recipe in
            if favoritesOnly, !recipe.favorite { return false }
            // Same result as tagFilters.isSubset(of: Set(recipe.tags)), without
            // allocating a fresh Set per recipe on every keystroke — tagFilters
            // and recipe.tags are both tiny, so a linear scan is cheaper.
            if !tagFilters.isEmpty, !tagFilters.allSatisfy(recipe.tags.contains) { return false }
            if let courseFilter, recipe.course != courseFilter { return false }
            if !recipe.matchesSourceFilter(sourceFilters) { return false }
            if needle.isEmpty { return true }
            return recipe.searchBlob.contains(needle)
        }

        // Ingredient filters: keep recipes that use every selected name
        // (AND), then rank by fit % (how much of that recipe the selection
        // covers). Sort chips are ignored while filters are active.
        var matches: [Int: RecipeMatch] = [:]
        if !have.isEmpty {
            rows = rows.filter { recipeMatchesIngredientFilter($0, ingredients: have) }
            for recipe in rows {
                matches[recipe.id] = matchRecipe(recipe, have: have)
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

        // Driven by the same search box as the recipe list (`query`), not a
        // separate one — typing something that matches a known ingredient
        // surfaces it as a suggestion right alongside the filtered recipe
        // results, rather than needing a whole separate Pantry search.
        // Gated behind actually typing something — as the recipe box grows,
        // the full catalog is too long to skim, so this is a search, not a
        // browsable list.
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
        rebuildTags()
        updateVisible()
    }

    private func rebuildTags() {
        tags = Array(Set(recipeTags).union(recipes.flatMap(\.tags))).sorted()
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

    /// Called after every optimistic update (a favorite tap, an edit, an
    /// add, a delete, a refresh) — encoding the whole recipe collection and
    /// writing it to disk synchronously here would block the main thread on
    /// actions that are meant to feel instant. Snapshotting `recipes`/
    /// `pantryGroups` has to happen here on the main actor (cheap — just
    /// copying array references), but the actual encode + disk write is
    /// pushed to a background task.
    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = RecipeCache(serverURL: serverURL, recipes: recipes, pantry: pantryGroups)
        Task.detached(priority: .utility) {
            guard let data = try? Self.encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct RecipeCache: Codable {
    let serverURL: String
    let recipes: [Recipe]
    let pantry: [PantryGroup]
}
