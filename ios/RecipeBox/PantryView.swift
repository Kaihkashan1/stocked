import SwiftUI

/// The pantry: ingredients you have on hand, plus a shopping list of things
/// you intend to buy. Drives sorting and "only what I can make" on the
/// Recipes tab — no more meal-planning/grocery-aggregation concept here,
/// just what you have and what you're missing.
struct PantryView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Add something you have (e.g. leftover turkey)", text: $newItem)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addTypedItem)
                    Button("Add", action: addTypedItem)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if store.selectedPantryGroups.isEmpty {
                    Text("Nothing marked yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.selectedPantryGroups) { group in
                        pantryGroup(group, selected: true)
                    }
                }
            } header: {
                Text("What I have")
            } footer: {
                Text("Tap an ingredient below, or add your own — this drives sorting and \"Only what I can make\" on the Recipes tab.")
            }

            Section {
                DebouncedTextField(placeholder: "Find an ingredient…", text: $store.pantryQuery)
                if store.visiblePantryGroups.isEmpty {
                    Text("No matching ingredients")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.visiblePantryGroups) { group in
                        pantryGroup(group, selected: false)
                    }
                }
            }

            if !store.pantryGroups.isEmpty {
                Section {
                    ForEach(store.pantryGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.category)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            FlowLayout(spacing: 8) {
                                ForEach(group.items, id: \.self) { item in
                                    let active = store.shoppingList.contains(item)
                                    Button {
                                        store.toggleShoppingItem(item)
                                    } label: {
                                        Text(active ? "\(item) ×" : item)
                                            .font(Theme.mono(12, weight: .semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(active ? Theme.accentSoft : Theme.surface)
                                            .foregroundStyle(active ? Theme.accent : Theme.inkSoft)
                                            .overlay(Capsule().strokeBorder(active ? .clear : Theme.line))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Shopping list")
                } footer: {
                    Text("Ingredients you plan to buy — check them off once they've made it into \"What I have\" above.")
                }
            }

            Color.clear
                .frame(height: 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
    }

    private func addTypedItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addHaveItem(trimmed)
        newItem = ""
    }

    private func pantryGroup(_ group: PantryGroup, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.category)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            FlowLayout(spacing: 8) {
                ForEach(group.items, id: \.self) { item in
                    Button {
                        store.toggleIngredient(item)
                    } label: {
                        Text(selected ? "\(item) ×" : item)
                            .font(Theme.mono(12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.accentSoft : Theme.surface)
                            .foregroundStyle(selected ? Theme.accent : Theme.inkSoft)
                            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.line))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id("\(selected ? "have" : "add")-\(group.category)")
    }
}
