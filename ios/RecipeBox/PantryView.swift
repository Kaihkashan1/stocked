import SwiftUI

/// The pantry: ingredients you have on hand. Drives sorting on the Recipes
/// tab — no meal-planning/grocery-aggregation, no shopping list, just what
/// you have. One box does both jobs: type to filter the catalog down to
/// matching chips to select, and/or add whatever you typed as a new item
/// if it isn't already one of them.
struct PantryView: View {
    @EnvironmentObject private var store: RecipeStore

    var body: some View {
        List {
            Section {
                if store.selectedPantryGroups.isEmpty {
                    Text("Nothing marked yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.selectedPantryGroups) { group in
                        pantryGroup(group, selected: true)
                    }
                }

                DebouncedTextField(placeholder: "Add or find an ingredient…", text: $store.pantryQuery)

                let trimmed = store.pantryQuery.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    ForEach(store.visiblePantryGroups) { group in
                        pantryGroup(group, selected: false)
                    }
                    if store.canAddTypedPantryItem(trimmed) {
                        Button {
                            store.addHaveItem(trimmed)
                            store.pantryQuery = ""
                        } label: {
                            Label("Add “\(trimmed)”", systemImage: "plus.circle.fill")
                        }
                    } else if store.visiblePantryGroups.isEmpty {
                        Text("No matching ingredients")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What I have")
            } footer: {
                Text("Type to find an ingredient to select, or add something new — this drives sorting on the Recipes tab.")
            }

            Color.clear
                .frame(height: 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
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
