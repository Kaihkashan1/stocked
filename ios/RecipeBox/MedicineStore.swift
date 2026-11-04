import Foundation
import Observation

/// The Medicines tab — same shape as PantryStore (Cupboard) but for
/// MedicineItem, and without Cupboard's to-buy list or custom-category CRUD
/// (medicine categories are a fixed list the server returns, not something
/// the client edits).
@Observable @MainActor
final class MedicineStore {
    var items: [MedicineItem] = [] {
        didSet {
            if oldValue != items { rebuildGroups() }
        }
    }
    var categories: [String] = defaultMedicineCategories {
        didSet {
            if oldValue != categories { rebuildGroups() }
        }
    }
    var isLoading = false
    var actionError: String?
    var lastRefreshError: String?

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()
    private static let urlKey = "recipeBox.serverURL"
    private static let secretKey = "recipeBox.serverSecret"
    private static let cacheName = "medicinesCache.json"
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var lastSuccessfulRefresh: Date?
    private static let staleInterval: TimeInterval = 90

    init() {
        loadCache()
    }

    var itemCount: Int { items.count }

    /// Items grouped in server category order; empty categories omitted.
    private(set) var groupedItems: [(category: String, items: [MedicineItem])] = []

    private func rebuildGroups() {
        groupedItems = categories.compactMap { name in
            let rows = items.filter { $0.category.caseInsensitiveCompare(name) == .orderedSame }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !rows.isEmpty else { return nil }
            return (name, rows)
        }
    }

    private var serverURL: String {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? RecipeStore.hostedURL : value
    }

    private var serverSecret: String {
        UserDefaults.standard.string(forKey: Self.secretKey) ?? ""
    }

    @discardableResult
    func refresh(force: Bool = true, auto: Bool = false) async -> Bool {
        if !force, let lastSuccessfulRefresh, Date().timeIntervalSince(lastSuccessfulRefresh) < Self.staleInterval {
            return true
        }
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await loadRemote(auto: auto) }
        refreshTask = task
        let result = await task.value
        if refreshTask == task {
            refreshTask = nil
        }
        return result
    }

    private func loadRemote(auto: Bool) async -> Bool {
        let hadCache = !items.isEmpty
        if !hadCache {
            isLoading = true
        }
        defer { isLoading = false }

        if await fetchOnce() {
            lastRefreshError = nil
            return true
        }
        // Same one-retry-then-surface pattern as RecipeStore/PantryStore — a
        // silent automatic refresh failing over an existing cache used to
        // look identical to "nothing changed".
        guard auto, hadCache, !Task.isCancelled else { return false }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard !Task.isCancelled else { return false }
        if await fetchOnce() {
            lastRefreshError = nil
            return true
        }
        lastRefreshError = "Couldn't refresh — pull down to try again."
        return false
    }

    private func fetchOnce() async -> Bool {
        do {
            let payload = try await APIClient(baseURLString: serverURL).fetchMedicines()
            let nextCategories = payload.categories?.isEmpty == false ? payload.categories! : categories
            if items != payload.items { items = payload.items }
            if categories != nextCategories { categories = nextCategories }
            lastSuccessfulRefresh = Date()
            persistCache()
            return true
        } catch {
            return false
        }
    }

    func upsertItem(_ item: MedicineItem) {
        var next = items
        if let index = next.firstIndex(where: { $0.id == item.id }) {
            next[index] = item
        } else {
            next.append(item)
        }
        replaceInventory(next)
    }

    func deleteItem(id: String) {
        replaceInventory(items.filter { $0.id != id })
    }

    private func replaceInventory(_ next: [MedicineItem]) {
        let previous = items
        items = next
        persistCache()
        let snapshot = items
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .updateMedicines(items: snapshot, secret: serverSecret)
                if items == snapshot {
                    items = confirmed.items
                    if let remote = confirmed.categories, !remote.isEmpty {
                        categories = remote
                    }
                    persistCache()
                }
            } catch {
                if items == snapshot {
                    items = previous
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    private func cacheURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.cacheName)
    }

    private func loadCache() {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(MedicineCache.self, from: data),
              payload.serverURL == serverURL
        else { return }
        items = payload.items
        if let stored = payload.categories, !stored.isEmpty {
            categories = stored
        }
    }

    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = MedicineCache(serverURL: serverURL, items: items, categories: categories)
        Task.detached(priority: .utility) {
            guard let data = try? Self.encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct MedicineCache: Codable {
    let serverURL: String
    let items: [MedicineItem]
    var categories: [String]?
}
