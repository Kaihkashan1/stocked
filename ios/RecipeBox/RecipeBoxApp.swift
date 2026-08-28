import SwiftUI

@main
struct RecipeBoxApp: App {
    @State private var store = RecipeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { url in
                    store.pendingRoute = Self.route(for: url)
                }
        }
    }

    /// Parses a recipebox:// deep link, e.g. from a Shortcuts action:
    /// recipebox://pantry, recipebox://surprise, recipebox://have?items=chicken,rice
    static func route(for url: URL) -> DeepLinkRoute? {
        guard url.scheme?.lowercased() == "recipebox" else { return nil }
        switch url.host?.lowercased() {
        case "pantry", "plan": // "plan" kept for shortcuts saved before the rename
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
