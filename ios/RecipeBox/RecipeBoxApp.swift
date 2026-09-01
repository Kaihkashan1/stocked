import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .system: L("System")
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    var locale: Locale {
        switch self {
        case .system: Locale.autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .german: Locale(identifier: "de")
        }
    }
}

/// Looks up a catalog string in the in-app language, not the phone language.
/// `Text("Save")` already follows SwiftUI's locale environment; this is for
/// `String` kickers, placeholders, errors, and accessibility labels.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, locale: LanguageStore.shared.language.locale)
}

@Observable
final class LanguageStore {
    static let shared = LanguageStore()
    private static let key = "appLanguage"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }
}

@main
struct RecipeBoxApp: App {
    @State private var store = RecipeStore()
    @State private var pantryStore = PantryStore()
    @State private var connectivity = Connectivity()
    @State private var languageStore = LanguageStore.shared

    init() {
        BundledFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pantryStore)
                .environment(connectivity)
                .environment(languageStore)
                .environment(\.locale, languageStore.language.locale)
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
