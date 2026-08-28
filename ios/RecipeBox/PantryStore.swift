import Foundation
import Observation

/// Inventory + to-buy for the Pantry tab. Independent of RecipeStore.have
/// (the list-screen fit filter). Shares server URL/secret UserDefaults keys
/// with RecipeStore so Settings changes apply here without a second form.
@Observable @MainActor
final class PantryStore {
    var items: [PantryItem] = []
    var toBuy: [ToBuyItem] = []
    var isLoading = false
    var actionError: String?

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()
    private static let urlKey = "recipeBox.serverURL"
    private static let secretKey = "recipeBox.serverSecret"
    private static let cacheName = "pantryInventoryCache.json"

    init() {
        loadCache()
    }

    var itemCount: Int { items.count }
    var toBuyCount: Int { toBuy.count }

    var kickerLine: String {
        let itemPart = itemCount == 1 ? "1 item" : "\(itemCount) items"
        let buyPart = toBuyCount == 1 ? "1 to buy" : "\(toBuyCount) to buy"
        return "\(itemPart) · \(buyPart)"
    }

    /// Items grouped in handoff category order; empty categories omitted.
    var groupedItems: [(category: PantryCategory, items: [PantryItem])] {
        PantryCategory.allCases.compactMap { category in
            let rows = items.filter { $0.pantryCategory == category }
            guard !rows.isEmpty else { return nil }
            return (category, rows)
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
    func refresh() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = APIClient(baseURLString: serverURL)
            async let inventory = client.fetchPantryInventory()
            async let buyList = client.fetchToBuy()
            items = try await inventory
            toBuy = try await buyList
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

    func replaceInventory(_ next: [PantryItem]) {
        let previous = items
        items = next
        persistCache()
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .updatePantryInventory(items: next, secret: serverSecret)
                if items == next {
                    items = confirmed
                    persistCache()
                }
            } catch {
                if items == next {
                    items = previous
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    func addToBuy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if toBuy.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        replaceToBuy(toBuy + [ToBuyItem(text: trimmed)])
    }

    func removeToBuy(id: String) {
        replaceToBuy(toBuy.filter { $0.id != id })
    }

    /// Toggle by ingredient text (case-insensitive) — used from recipe detail.
    func toggleToBuy(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = toBuy.firstIndex(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            var next = toBuy
            next.remove(at: index)
            replaceToBuy(next)
        } else {
            replaceToBuy(toBuy + [ToBuyItem(text: trimmed)])
        }
    }

    func isInToBuy(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return toBuy.contains { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func toggleChecked(id: String) {
        var next = toBuy
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].checked.toggle()
        replaceToBuy(next)
    }

    func replaceToBuy(_ next: [ToBuyItem]) {
        let previous = toBuy
        toBuy = next
        persistCache()
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .updateToBuy(items: next, secret: serverSecret)
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
    }

    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = PantryCache(serverURL: serverURL, items: items, toBuy: toBuy)
        Task.detached(priority: .utility) {
            guard let data = try? Self.encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct PantryCache: Codable {
    let serverURL: String
    let items: [PantryItem]
    let toBuy: [ToBuyItem]
}
