import SwiftUI

/// The pantry: ingredients you have on hand. Drives sorting on the Recipes
/// tab — no meal-planning/grocery-aggregation, no shopping list, just what
/// you have.
struct PantryView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Add something you have", text: $newItem)
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
                Text("Tap an ingredient below, or add your own — this drives sorting on the Recipes tab.")
            }

            Section {
                DebouncedTextField(placeholder: "Find an ingredient…", text: $store.pantryQuery)
                if store.pantryQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type to find an ingredient")
                        .foregroundStyle(.secondary)
                } else if store.visiblePantryGroups.isEmpty {
                    Text("No matching ingredients")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.visiblePantryGroups) { group in
                        pantryGroup(group, selected: false)
                    }
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
