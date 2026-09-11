import Foundation
import Observation

/// Inventory + to-buy for the Pantry tab. Independent of RecipeStore.have
/// (the list-screen fit filter). Shares server URL/secret UserDefaults keys
/// with RecipeStore so Settings changes apply here without a second form.
@Observable @MainActor
final class PantryStore {
    var items: [PantryItem] = [] {
        didSet {
            if oldValue != items { rebuildGroups() }
        }
    }
    var categories: [String] = defaultPantryCategories {
        didSet {
            if oldValue != categories { rebuildGroups() }
        }
    }
    var toBuy: [ToBuyItem] = []
    var isLoading = false
    var actionError: String?

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()
    private static let urlKey = "recipeBox.serverURL"
    private static let secretKey = "recipeBox.serverSecret"
    private static let cacheName = "pantryInventoryCache.json"
    @ObservationIgnored private var toBuySyncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var lastSuccessfulRefresh: Date?
    private static let staleInterval: TimeInterval = 90

    init() {
        loadCache()
    }

    var itemCount: Int { items.count }
    var toBuyCount: Int { toBuy.count }

    var kickerLine: String {
        let itemPart = L("\(itemCount) items")
        let buyPart = L("\(toBuyCount) to buy")
        return "\(itemPart) · \(buyPart)"
    }

    /// Items grouped in saved category order; empty categories omitted.
    /// Rebuilt when `items` or `categories` change rather than on every Cupboard body.
    private(set) var groupedItems: [(category: String, items: [PantryItem])] = []

    private func rebuildGroups() {
        groupedItems = mergePantryCategories(stored: categories, itemCategories: items.map(\.category)).compactMap { name in
            let rows = items.filter { $0.pantryCategory.caseInsensitiveCompare(name) == .orderedSame }
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
        let hadCache = !items.isEmpty || !toBuy.isEmpty
        if !hadCache {
            isLoading = true
        }
        defer { isLoading = false }
        do {
            let client = APIClient(baseURLString: serverURL)
            async let inventory = client.fetchPantryInventory()
            async let buyList = client.fetchToBuy()
            let payload = try await inventory
            let nextItems = payload.items
            let nextCategories = mergePantryCategories(
                stored: payload.categories ?? categories,
                itemCategories: nextItems.map(\.category)
            )
            let nextBuy = mergeToBuyNotes(server: try await buyList, local: toBuy)
            if items != nextItems { items = nextItems }
            if categories != nextCategories { categories = nextCategories }
            if toBuy != nextBuy { toBuy = nextBuy }
            lastSuccessfulRefresh = Date()
            persistCache()
            return true
        } catch {
            // Keep the cached lists on screen; only surface a write failure
            // via actionError. A cold empty cache stays empty until a later
            // successful refresh.
            return false
        }
    }

    func upsertItem(_ item: PantryItem) {
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

    func replaceInventory(_ next: [PantryItem], categories nextCategories: [String]? = nil) {
        let previousItems = items
        let previousCategories = categories
        items = next
        if let nextCategories {
            categories = mergePantryCategories(stored: nextCategories, itemCategories: next.map(\.category))
        }
        persistCache()
        let snapshotItems = items
        let snapshotCategories = categories
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .updatePantryInventory(items: snapshotItems, categories: snapshotCategories, secret: serverSecret)
                if items == snapshotItems, categories == snapshotCategories {
                    items = confirmed.items
                    if let remote = confirmed.categories {
                        categories = mergePantryCategories(stored: remote, itemCategories: confirmed.items.map(\.category))
                    }
                    persistCache()
                }
            } catch {
                if items == snapshotItems, categories == snapshotCategories {
                    items = previousItems
                    categories = previousCategories
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    func addCategory(_ raw: String) {
        guard let name = normalizePantryCategoryName(raw) else { return }
        if categories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return
        }
        guard categories.count < maxPantryCategories else { return }
        var next = categories
        if let other = next.firstIndex(where: { $0.caseInsensitiveCompare("Other") == .orderedSame }) {
            next.insert(name, at: other)
        } else {
            next.append(name)
        }
        replaceInventory(items, categories: next)
    }

    func renameCategory(_ from: String, to raw: String) {
        guard !isLockedPantryCategory(from) else { return }
        guard let name = normalizePantryCategoryName(raw) else { return }
        guard let index = categories.firstIndex(where: { $0.caseInsensitiveCompare(from) == .orderedSame }) else { return }
        if categories.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
                && $0.caseInsensitiveCompare(from) != .orderedSame
        }) {
            return
        }
        var next = categories
        next[index] = name
        let nextItems = items.map { item -> PantryItem in
            guard item.pantryCategory.caseInsensitiveCompare(from) == .orderedSame else { return item }
            var moved = item
            moved.category = name
            return moved
        }
        replaceInventory(nextItems, categories: next)
    }

    func deleteCategory(_ name: String) {
        guard !isLockedPantryCategory(name) else { return }
        let remaining = categories.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        guard remaining != categories else { return }
        let fallback = remaining.first(where: { $0.caseInsensitiveCompare("Other") == .orderedSame })
            ?? remaining.first
            ?? "Other"
        let nextCategories = remaining.isEmpty ? ["Other"] : remaining
        let nextItems = items.map { item -> PantryItem in
            guard item.pantryCategory.caseInsensitiveCompare(name) == .orderedSame else { return item }
            var moved = item
            moved.category = fallback
            return moved
        }
        replaceInventory(nextItems, categories: nextCategories)
    }

    func addToBuy(_ text: String, qty: String = "") {
        addToBuySource(text: text, qty: qty, recipeID: nil)
    }

    func removeToBuy(id: String) {
        replaceToBuy(toBuy.filter { $0.id != id })
    }

    func addToBuySource(text: String, qty: String = "", recipeID: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let qtyTrimmed = qty.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = toBuy
        let optimistic = applyingSource(to: previous, text: trimmed, qty: qtyTrimmed, recipeID: recipeID)
        toBuy = optimistic
        persistCache()
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .addToBuySource(text: trimmed, qty: qtyTrimmed, recipeID: recipeID, secret: serverSecret)
                if toBuy == optimistic {
                    toBuy = confirmed
                    persistCache()
                }
            } catch {
                if toBuy == optimistic {
                    toBuy = previous
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    func removeToBuySource(text: String, recipeID: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = toBuy
        let optimistic = removingSource(from: previous, text: trimmed, recipeID: recipeID)
        toBuy = optimistic
        persistCache()
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .removeToBuySource(text: trimmed, recipeID: recipeID, secret: serverSecret)
                if toBuy == optimistic {
                    toBuy = confirmed
                    persistCache()
                }
            } catch {
                if toBuy == optimistic {
                    toBuy = previous
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    func toggleToBuy(text: String, qty: String = "", recipeID: Int?) {
        if isInToBuy(text: text, recipeID: recipeID) {
            removeToBuySource(text: text, recipeID: recipeID)
        } else {
            addToBuySource(text: text, qty: qty, recipeID: recipeID)
        }
    }

    func isInToBuy(text: String, recipeID: Int?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let row = toBuy.first(where: { toBuyMatchKey($0.text) == toBuyMatchKey(trimmed) }) else {
            return false
        }
        return row.sources.contains { $0.recipeID == recipeID }
    }

    func toggleChecked(id: String) {
        var next = toBuy
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].checked.toggle()
        replaceToBuy(next)
    }

    /// Updates the manual (`recipeID == nil`) source; derived qty follows.
    func setToBuyQty(id: String, qty: String) {
        guard let index = toBuy.firstIndex(where: { $0.id == id }) else { return }
        var item = toBuy[index]
        if let sourceIndex = item.sources.firstIndex(where: { $0.recipeID == nil }) {
            if item.sources[sourceIndex].qty == qty { return }
            item.sources[sourceIndex].qty = qty
        } else {
            item.sources.append(ToBuySource(recipeID: nil, qty: qty))
        }
        item.qty = mergeToBuyQty(item.sources)
        toBuy[index] = item
        persistCache()
        scheduleToBuySync()
    }

    func setToBuyNotes(id: String, notes: String) {
        guard let index = toBuy.firstIndex(where: { $0.id == id }) else { return }
        if toBuy[index].notes == notes { return }
        toBuy[index].notes = notes
        persistCache()
        scheduleToBuySync()
    }

    func replaceToBuy(_ next: [ToBuyItem]) {
        let previous = toBuy
        toBuy = next
        persistCache()
        Task {
            do {
                let confirmed = mergeToBuyNotes(
                    server: try await APIClient(baseURLString: serverURL)
                        .updateToBuy(items: next, secret: serverSecret),
                    local: next
                )
                if toBuy == next {
                    toBuy = confirmed
                    persistCache()
                }
            } catch {
                if toBuy == next {
                    toBuy = previous
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    private func scheduleToBuySync() {
        toBuySyncTask?.cancel()
        let snapshot = toBuy
        toBuySyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                let confirmed = mergeToBuyNotes(
                    server: try await APIClient(baseURLString: serverURL)
                        .updateToBuy(items: snapshot, secret: serverSecret),
                    local: snapshot
                )
                // Only apply if the user hasn't typed further since this snapshot.
                if toBuy == snapshot {
                    toBuy = confirmed
                    persistCache()
                }
            } catch {
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
              let payload = try? Self.decoder.decode(PantryCache.self, from: data),
              payload.serverURL == serverURL
        else { return }
        items = payload.items
        toBuy = payload.toBuy
        if let stored = payload.categories, !stored.isEmpty {
            categories = mergePantryCategories(stored: stored, itemCategories: payload.items.map(\.category))
        }
    }

    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = PantryCache(serverURL: serverURL, items: items, toBuy: toBuy, categories: categories)
        Task.detached(priority: .utility) {
            guard let data = try? Self.encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private func applyingSource(to items: [ToBuyItem], text: String, qty: String, recipeID: Int?) -> [ToBuyItem] {
    var next = items
    let source = ToBuySource(recipeID: recipeID, qty: qty)
    if let index = next.firstIndex(where: { toBuyMatchKey($0.text) == toBuyMatchKey(text) }) {
        var item = next[index]
        item.sources.removeAll { $0.recipeID == recipeID }
        item.sources.append(source)
        item.qty = mergeToBuyQty(item.sources)
        item.checked = false
        next[index] = item
        return next
    }
    return next + [ToBuyItem(text: text, qty: qty, sources: [source])]
}

private func removingSource(from items: [ToBuyItem], text: String, recipeID: Int?) -> [ToBuyItem] {
    items.compactMap { item in
        guard toBuyMatchKey(item.text) == toBuyMatchKey(text) else { return item }
        var next = item
        next.sources.removeAll { $0.recipeID == recipeID }
        guard !next.sources.isEmpty else { return nil }
        next.qty = mergeToBuyQty(next.sources)
        return next
    }
}

private struct PantryCache: Codable {
    let serverURL: String
    let items: [PantryItem]
    let toBuy: [ToBuyItem]
    var categories: [String]?
}
