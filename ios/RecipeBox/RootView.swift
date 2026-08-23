import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var showSettings = false
    @State private var showAddRecipe = false
    @State private var selectedTab = 0
    @State private var recipesPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $recipesPath) {
                RecipeListView()
                    .navigationTitle("Recipe Box")
                    .toolbar { addButton }
                    .toolbar { settingsButton }
            }
            .tabItem { Label("Recipes", systemImage: "book.closed") }
            .tag(0)

            NavigationStack {
                GroceryListView()
                    .navigationTitle("Plan")
                    .toolbar { settingsButton }
            }
            .tabItem { Label("Plan", systemImage: "cart") }
            .badge(store.planIDs.isEmpty ? nil : "\(store.planIDs.count)")
            .tag(1)
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddRecipe) {
            AddRecipeView()
                .environmentObject(store)
        }
        .task { await store.refresh() }
        .onChange(of: store.pendingRoute) { _, route in
            handle(route)
        }
    }

    private var addButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddRecipe = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add recipe")
        }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Server settings")
        }
    }

    private func handle(_ route: DeepLinkRoute?) {
        guard let route else { return }
        switch route {
        case .plan:
            selectedTab = 1
        case .have(let items):
            selectedTab = 0
            recipesPath = NavigationPath()
            store.have = items
        case .surprise:
            selectedTab = 0
            if let recipe = store.recipes.randomElement() {
                recipesPath = NavigationPath()
                recipesPath.append(recipe.id)
            }
        }
        store.pendingRoute = nil
    }
}
