import SwiftUI
import UIKit

struct RecipeListView: View {
    @EnvironmentObject private var store: RecipeStore

    private let meals = [
        ("all", "All meals"),
        ("breakfast", "Breakfast"),
        ("lunch", "Lunch"),
        ("dinner", "Dinner"),
        ("snack", "Snack"),
        ("dessert", "Dessert"),
        ("drink", "Drink"),
        ("other", "Other"),
    ]

    var body: some View {
        List {
            Section {
                DebouncedTextField(
                    placeholder: "Search recipes or ingredients you have…",
                    text: $store.query
                )
                ForEach(store.selectedPantryGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.category)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        FilterWrap(items: group.items, selected: store.haveSet) { item in
                            store.toggleIngredient(item)
                        }
                    }
                    .id("have-\(group.category)")
                }
                if !store.visiblePantryGroups.isEmpty {
                    ForEach(store.visiblePantryGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Add \(group.category.lowercased())")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            FilterWrap(items: group.items, selected: store.haveSet) { item in
                                store.toggleIngredient(item)
                            }
                        }
                        .id("pantry-\(group.category)")
                    }
                }
            } footer: {
                Text("Type a dish, tag, or ingredient. Tap an ingredient to keep it as something you have.")
            }

            Section("Meal") {
                FilterRow(
                    options: meals,
                    selection: $store.mealFilter
                )
                Button {
                    store.favoritesOnly.toggle()
                } label: {
                    Label(
                        store.favoritesOnly ? "Showing favorites" : "Favorites only",
                        systemImage: store.favoritesOnly ? "star.fill" : "star"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.favoritesOnly ? Theme.accent : Theme.inkSoft)
            }

            if !store.cuisines.isEmpty {
                Section("Cuisine") {
                    FilterRow(
                        options: [("all", "All cuisines")] + store.cuisines.map { ($0, $0) },
                        selection: $store.cuisineFilter
                    )
                }
            }

            if let message = store.errorMessage, store.recipes.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Can't load recipes")
                            .font(.headline)
                        Text(message)
                            .foregroundStyle(.secondary)
                        Text("Pull to retry. If it keeps failing, open Settings and confirm the server address.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else if store.visibleRecipes.isEmpty, !store.isLoading {
                Section {
                    Text("No recipes match those filters yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(store.visibleRecipes.count) recipe\(store.visibleRecipes.count == 1 ? "" : "s")") {
                    ForEach(store.visibleRecipes) { recipe in
                        NavigationLink(value: recipe.id) {
                            EquatableView(content: RecipeRow(recipe: recipe, match: store.matchesByID[recipe.id]))
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await store.toggleFavorite(recipe) }
                            } label: {
                                Label("Favorite", systemImage: recipe.favorite ? "star.slash" : "star.fill")
                            }
                            .tint(Theme.warm)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                store.togglePlan(recipe)
                            } label: {
                                Label(
                                    store.planIDs.contains(recipe.id) ? "Remove" : "Add to plan",
                                    systemImage: store.planIDs.contains(recipe.id) ? "cart.badge.minus" : "cart.badge.plus"
                                )
                            }
                            .tint(Theme.accent)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Int.self) { id in
            RecipeDetailView(id: id)
        }
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading, store.recipes.isEmpty {
                ProgressView("Loading recipes…")
            }
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { shown in if !shown { store.actionError = nil } }
            ),
            presenting: store.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

struct DebouncedTextField: View {
    let placeholder: String
    @Binding var text: String
    var delay: Duration = .milliseconds(160)

    @State private var draft = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        TextField(placeholder, text: $draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onAppear { draft = text }
            .onChange(of: text) { _, new in
                if new != draft { draft = new }
            }
            .onChange(of: draft) { _, new in
                task?.cancel()
                task = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    if text != new {
                        text = new
                    }
                }
            }
    }
}

struct FilterRow: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { option in
                    Button {
                        selection = option.0
                    } label: {
                        Text(option.1)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selection == option.0 ? Theme.accent : Theme.bg)
                            .foregroundStyle(selection == option.0 ? Color.white : Theme.inkSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

struct FilterWrap: View {
    let items: [String]
    let selected: Set<String>
    let onTap: (String) -> Void

    var body: some View {
        FlexibleChipRow(items: items, selected: selected, onTap: onTap)
    }
}

struct FlexibleChipRow: View {
    let items: [String]
    let selected: Set<String>
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button {
                        onTap(item)
                    } label: {
                        Text(selected.contains(item) ? "\(item) ×" : item)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected.contains(item) ? Theme.accent : Theme.bg)
                            .foregroundStyle(selected.contains(item) ? Color.white : Theme.inkSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

struct RecipeRow: View, Equatable {
    let recipe: Recipe
    var match: RecipeMatch? = nil

    static func == (lhs: RecipeRow, rhs: RecipeRow) -> Bool {
        lhs.recipe.id == rhs.recipe.id
            && lhs.recipe.title == rhs.recipe.title
            && lhs.recipe.thumbnail == rhs.recipe.thumbnail
            && lhs.recipe.cuisine == rhs.recipe.cuisine
            && lhs.recipe.meal == rhs.recipe.meal
            && lhs.match?.label == rhs.match?.label
    }

    var body: some View {
        HStack(spacing: 12) {
            RecipeThumb(recipe: recipe, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let match {
                        Text(match.label)
                    } else {
                        Text(recipe.cuisine)
                    }
                    if match == nil, recipe.meal != "other" {
                        Text("·")
                        Text(recipe.mealLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RecipeThumb: View {
    let recipe: Recipe
    var size: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.bg)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: recipe.thumbnail) {
            guard let url = recipe.thumbnailURL else {
                image = nil
                return
            }
            image = await ThumbnailCache.shared.image(for: url, maxPixel: size * 3)
        }
    }

    private var letter: some View {
        Text(String(recipe.title.prefix(1)).uppercased())
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.accent)
    }
}
