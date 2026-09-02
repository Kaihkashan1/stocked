import SwiftUI

/// Catalog lookup forced to English — Stocked does not ship in-app
/// translations. `Text("Save")` also follows `.environment(\.locale)`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, locale: Locale(identifier: "en"))
}

@main
struct RecipeBoxApp: App {
    @State private var store = RecipeStore()
    @State private var pantryStore = PantryStore()
    @State private var connectivity = Connectivity()

    init() {
        BundledFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pantryStore)
                .environment(connectivity)
                .environment(\.locale, Locale(identifier: "en"))
                .onOpenURL { url in
                    store.pendingRoute = Self.route(for: url)
                }
        }
    }

    /// Parses a recipebox:// deep link, e.g. from a Shortcuts action:
    /// recipebox://cupboard (Cupboard tab; recipebox://pantry still works),
    /// recipebox://surprise, recipebox://have?items=chicken,rice
    static func route(for url: URL) -> DeepLinkRoute? {
        guard url.scheme?.lowercased() == "recipebox" else { return nil }
        switch url.host?.lowercased() {
        case "cupboard", "pantry", "plan":
            return .pantry
        case "surprise":
            return .surprise
        case "have":
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "items" })?.value ?? ""
            let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .have(items)
        default:
            return nil
        }
    }
}
