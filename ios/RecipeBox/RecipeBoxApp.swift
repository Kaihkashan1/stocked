import SwiftUI

@main
struct RecipeBoxApp: App {
    @StateObject private var store = RecipeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
