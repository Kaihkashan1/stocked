import SwiftUI
import UIKit

struct RecipeListView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var showFilters = false

    private var activeFilterCount: Int {
        [!store.tagFilters.isEmpty, store.favoritesOnly].filter { $0 }.count
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    DebouncedTextField(placeholder: "Search title, ingredient, tag…", text: $store.query)
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20))
                    }
                    .foregroundStyle(activeFilterCount > 0 ? Theme.accent : Theme.inkSoft)
                    .accessibilityLabel("Filters")
                }
            } footer: {
                if !store.have.isEmpty {
                    Text("Sorted by closest fit to your pantry — manage \"What I have\" on the Pantry tab.")
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
                    }
                }
            }

            // Clears the floating tab bar so the last row/link is never
            // hidden behind it.
            Color.clear
                .frame(height: 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
        .sheet(isPresented: $showFilters) {
            FiltersSheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
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

struct FiltersSheet: View {
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.favoritesOnly.toggle()
                    } label: {
                        Label(
                            store.favoritesOnly ? "Showing favorites" : "Favorites only",
                            systemImage: store.favoritesOnly ? "star.fill" : "star"
                        )
                        .font(Theme.mono(12.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.favoritesOnly ? Theme.warm : Theme.inkSoft)
                }

                if !store.tags.isEmpty {
                    Section {
                        FilterWrap(items: store.tags, selected: store.tagFilters) { tag in
                            if store.tagFilters.contains(tag) {
                                store.tagFilters.remove(tag)
                            } else {
                                store.tagFilters.insert(tag)
                            }
                        }
                    } header: {
                        Text("Tag")
                    } footer: {
                        Text("Any category — diet, course, source, appliance. Select any that apply.")
                    }
                }

                Section {
                    Picker("Sort", selection: $store.sortOption) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Sort")
                } footer: {
                    if !store.have.isEmpty {
                        Text("Ignored while \"what I have\" is active — closest fit always comes first then.")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        store.tagFilters = []
                        store.favoritesOnly = false
                        store.sortOption = .recent
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                            .font(Theme.mono(12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected.contains(item) ? Theme.accentSoft : Theme.surface)
                            .foregroundStyle(selected.contains(item) ? Theme.accent : Theme.inkSoft)
                            .overlay(
                                Capsule().strokeBorder(selected.contains(item) ? .clear : Theme.line)
                            )
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
            && lhs.match?.label == rhs.match?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(recipe.title)
                .font(Theme.display(17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let match {
                pill(match.label, background: Theme.accent, foreground: .white)
            }
        }
        .padding(.vertical, 8)
    }

    private func pill(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text.uppercased())
            .font(Theme.mono(10.5, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

