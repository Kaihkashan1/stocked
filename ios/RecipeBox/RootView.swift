import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            RecipeListView()
                .navigationTitle("Recipe Box")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Server settings")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environmentObject(store)
                }
        }
        .tint(Theme.accent)
        .task { await store.refresh() }
    }
}
