import Foundation

struct RecipesResponse: Codable {
    let recipes: [Recipe]
    let pantry: [PantryGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try container.decode([Recipe].self, forKey: .recipes)
        let groups = try container.decodeIfPresent([PantryGroup].self, forKey: .pantry) ?? []
        pantry = groups.map { PantryGroup(category: $0.category, items: collapsePantryItems($0.items)) }
    }

    enum CodingKeys: String, CodingKey {
        case recipes, pantry
    }
}

struct PantryGroup: Codable, Hashable, Identifiable {
    var id: String { category }
    let category: String
    let items: [String]
}

/// Fixed category order for the Pantry tab inventory (handoff §11).
enum PantryCategory: String, CaseIterable, Identifiable, Codable {
    case produce = "Produce"
    case dairyEggs = "Dairy & eggs"
    case meatSeafood = "Meat & seafood"
    case grainsPantry = "Grains & pantry"
    case condimentsSpices = "Condiments & spices"
    case other = "Other"

    var id: String { rawValue }

    static func resolve(_ raw: String) -> PantryCategory {
        Self(rawValue: raw) ?? .other
    }
}

enum PantryUnit: String, CaseIterable, Identifiable, Codable {
    case pcs, g, kg
    var id: String { rawValue }
}

enum PantryItemStatus: String, CaseIterable, Identifiable, Codable {
    case unopened
    case open
    var id: String { rawValue }

    var label: String {
        switch self {
        case .unopened: "Unopened"
        case .open: "Open"
        }
    }
}

/// One row on the Pantry tab's Items list — independent of recipe `have`
/// fit filtering and of `PantryGroup` (the catalog of ingredient names).
struct PantryItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var category: String
    var amount: Double
    var unit: PantryUnit
    var status: PantryItemStatus
    /// ISO date-only string `YYYY-MM-DD`, when set.
    var expiry: String?
    var notes: String

    var pantryCategory: PantryCategory { PantryCategory.resolve(category) }

    init(
        id: String = UUID().uuidString,
        name: String,
        category: PantryCategory = .other,
        amount: Double = 1,
        unit: PantryUnit = .pcs,
        status: PantryItemStatus = .unopened,
        expiry: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category.rawValue
        self.amount = amount
        self.unit = unit
        self.status = status
        self.expiry = expiry
        self.notes = notes
    }
}

struct ToBuyItem: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var checked: Bool

    init(id: String = UUID().uuidString, text: String, checked: Bool = false) {
        self.id = id
        self.text = text
        self.checked = checked
    }
}

struct PantryInventoryResponse: Codable {
    let items: [PantryItem]
}

struct ToBuyResponse: Codable {
    let items: [ToBuyItem]
}

struct Recipe: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let ingredients: [String]
    let steps: [String]
    let source: String
    let confidence: String
    let savedAt: String?
    /// Main course / Appetizers / Desserts — a direct field from the sheet
    /// now (see app.store's "Course" column), not derived from a `meal`
    /// classification the way it used to be.
    let course: Course
    let tags: [String]
    let pantry: [String]
    let favorite: Bool
    let notes: String
    /// Lowercased blob used for search so we do not rebuild it on every keystroke.
    let searchBlob: String

    // Equality is field-wise (synthesized) and has to stay that way: it is
    // what RecipeStore's @Observable properties use to decide whether a write
    // is a real change worth notifying SwiftUI about. An id-only == made
    // `recipes = payload.recipes` look like a no-op whenever a refresh brought
    // back the same rows with different contents, so a favorite set on another
    // device landed in the store but never redrew. Anything that wants
    // identity rather than value compares `id` explicitly.

    enum CodingKeys: String, CodingKey {
        case id, title, ingredients, steps, source, confidence, course, tags, pantry, favorite, notes
        case savedAt = "saved_at"
    }

    /// Memberwise init for building a locally-modified copy (optimistic
    /// favorite toggles) without a round trip through Codable.
    init(
        id: Int, title: String, ingredients: [String], steps: [String],
        source: String, confidence: String, savedAt: String?,
        course: Course, tags: [String], pantry: [String],
        favorite: Bool, notes: String, searchBlob: String
    ) {
        self.id = id
        self.title = title
        self.ingredients = ingredients
        self.steps = steps
        self.source = source
        self.confidence = confidence
        self.savedAt = savedAt
        self.course = course
        self.tags = tags
        self.pantry = pantry
        self.favorite = favorite
        self.notes = notes
        self.searchBlob = searchBlob
    }

    func withFavorite(_ value: Bool) -> Recipe {
        Recipe(
            id: id, title: title, ingredients: ingredients, steps: steps,
            source: source, confidence: confidence,
            savedAt: savedAt, course: course, tags: tags, pantry: pantry,
            favorite: value, notes: notes, searchBlob: searchBlob
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        ingredients = try container.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        let courseRaw = try container.decodeIfPresent(String.self, forKey: .course)
        course = courseRaw.flatMap(Course.init(rawValue:)) ?? .mainCourse
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        pantry = collapsePantryItems(try container.decodeIfPresent([String].self, forKey: .pantry) ?? [])
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        searchBlob = ([title, course.rawValue] + tags + ingredients).joined(separator: " ").lowercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(ingredients, forKey: .ingredients)
        try container.encode(steps, forKey: .steps)
        try container.encode(source, forKey: .source)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encode(course.rawValue, forKey: .course)
        try container.encode(tags, forKey: .tags)
        try container.encode(pantry, forKey: .pantry)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(notes, forKey: .notes)
    }

    var sourceURL: URL? {
        URL(string: source)
    }

    private static let savedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let savedAtRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "SAVED 2 DAYS AGO" — the hero kicker on the detail screen. Falls back
    /// to nil (kicker just isn't shown) if `saved_at` is missing or in a
    /// shape the store hasn't written before.
    var savedAtRelativeLabel: String? {
        guard let savedAt, let date = Self.savedAtFormatter.date(from: savedAt) else { return nil }
        return "Saved " + Self.savedAtRelativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Short, human label for the meta row / detail footer — "INSTAGRAM",
    /// "YOUTUBE", "TIKTOK", the bare host for any other link, or "Typed in"
    /// for a hand-entered recipe (source is "" for those — see store.py).
    var sourceLabel: String {
        guard let host = sourceURL?.host?.lowercased(), !host.isEmpty else {
            return "Typed in"
        }
        if host.contains("instagram.com") { return "Instagram" }
        if host.contains("youtube.com") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("tiktok.com") { return "TikTok" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// The Filters sheet's Source row bucket for this recipe. Instagram,
    /// YouTube and TikTok are read straight off the URL; anything else with
    /// a URL is "Link". A recipe with no URL is "Typed in" — Photo and
    /// Typed in are NOT actually distinguishable from stored data (both
    /// save with an empty Source column; see store.py's "typed in by hand"
    /// path, which a photo extraction also goes through once you hit Save),
    /// so `.photo` never matches anything today. It's kept in the enum and
    /// offered as its own chip because the handoff calls for both — should
    /// the sheet ever grow a real Photo/Typed-in marker, only this switch
    /// needs to change.
    var sourceCategory: SourceCategory {
        guard let host = sourceURL?.host?.lowercased(), !host.isEmpty else {
            return .typedIn
        }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("tiktok.com") { return .tiktok }
        return .link
    }

    /// True if this recipe belongs to any of the selected Source chips. A
    /// no-URL recipe matches both "Typed in" and "Photo" — see the doc
    /// comment on `sourceCategory` — so picking either one surfaces it,
    /// rather than "Photo" being a chip that can never match anything.
    func matchesSourceFilter(_ selected: Set<SourceCategory>) -> Bool {
        guard !selected.isEmpty else { return true }
        if selected.contains(sourceCategory) { return true }
        return sourceCategory == .typedIn && selected.contains(.photo)
    }
}

/// The three-way classification new to this redesign — "Main course" /
/// "Appetizers" / "Desserts" — shown as a filter row and a detail pill. A
/// direct field on a saved Recipe (see app.store's "Course" column) rather
/// than derived from `meal` the way it used to be, back when Course rode
/// along on the Meal column instead of having one of its own.
enum Course: String, CaseIterable, Identifiable {
    case mainCourse = "Main course"
    case appetizers = "Appetizers"
    case desserts = "Desserts"

    var id: String { rawValue }

    /// Only used to seed an initial guess from a photo extraction's Gemini
    /// `meal` classification (see RecipeExtraction) before the user picks a
    /// course explicitly in the Add-recipe form — extraction still reasons
    /// in terms of meal, saving no longer does.
    init(meal: String) {
        switch meal {
        case "dessert": self = .desserts
        case "snack": self = .appetizers
        default: self = .mainCourse
        }
    }
}

/// The Filters sheet's Source chip row — see `Recipe.sourceCategory`.
enum SourceCategory: String, CaseIterable, Identifiable {
    case instagram = "Instagram"
    case youtube = "YouTube"
    case tiktok = "TikTok"
    case link = "Link"
    case photo = "Photo"
    case typedIn = "Typed in"

    var id: String { rawValue }
}

/// Partial edit sent to PATCH /api/recipes/{id}. Optional properties are
/// synthesized with encodeIfPresent, so an unset field is simply omitted
/// from the request body — the server leaves it untouched.
struct RecipePatch: Encodable {
    var title: String?
    var ingredients: [String]?
    var steps: [String]?
    var favorite: Bool?
    var notes: String?
    var tags: [String]?
    var course: String?
}

/// What POST /api/extract-photo hands back after reading a recipe out of a
/// photo — not saved yet. The app pre-fills AddRecipeView with this so the
/// user can review/fix it before it's actually created, since a single
/// still photo (no caption text to fall back on) is more error-prone than
/// a normal capture.
struct RecipeExtraction: Decodable {
    let title: String
    let servings: String?
    let ingredients: [String]
    let steps: [String]
    let cuisine: String
    let meal: String
    let time: String?
    let tags: [String]
    let confidence: String
}

/// What POST /ingest hands back — the same endpoint the Save Recipe
/// Shortcut uses. `status` is "saved", "duplicate", "queued" (background
/// processing, local dev only — the hosted Vercel backend always finishes
/// in-request) or "error".
struct IngestResult: Decodable {
    let status: String
    let url: String?
    let title: String?
    let confidence: String?
    let message: String?
    let error: String?
}

/// What RecipeStore.ingestLink resolves to, once it's found (or given up
/// looking for) the row /ingest produced.
enum LinkIngestOutcome {
    case saved(Recipe)
    case error(String)
}

/// Backs the Settings screen's "API usage" card, from GET /api/usage.
/// `apify` is nil when the server has no Apify token or the live account
/// query failed — the card shows only the Gemini bar in that case rather
/// than a faked dollar figure.
struct UsageStats: Decodable {
    let gemini: GeminiUsage
    let apify: ApifyUsage?

    struct GeminiUsage: Decodable {
        let used: Int
        let limit: Int

        private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
        private static let cet = TimeZone(identifier: "CET")!
        private static let display: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "h a"
            formatter.timeZone = cet
            return formatter
        }()

        /// "Resets around 9 AM CET" — Gemini's free tier actually resets at
        /// midnight Pacific (that's the real clock; see GEMINI_QUOTA_MESSAGE
        /// server-side), converted here to CET so the Settings card shows a
        /// time that means something without doing the math yourself. Not
        /// server data — computed fresh against "now" each time, so it
        /// stays correct as Pacific and CET daylight saving shift through
        /// the year.
        static var resetsLabel: String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = pacific
            let startOfToday = calendar.startOfDay(for: Date())
            let nextMidnightPacific = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
            return "Resets around \(display.string(from: nextMidnightPacific)) CET"
        }
    }

    struct ApifyUsage: Decodable {
        let usedUsd: Double
        let limitUsd: Double
        /// ISO 8601 — the end of Apify's current monthly-credit cycle
        /// (the account's own billing-cycle anniversary, not the 1st of the
        /// month). Absent on an older backend or if Apify didn't include it.
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case usedUsd = "used_usd"
            case limitUsd = "limit_usd"
            case resetsAt = "resets_at"
        }

        private static let parser: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let fallbackParser = ISO8601DateFormatter()
        private static let display: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter
        }()

        /// "Resets Sep 15" — nil (caption just isn't shown) if `resetsAt`
        /// is missing or in a shape that doesn't parse.
        var resetsLabel: String? {
            guard let resetsAt else { return nil }
            let date = Self.parser.date(from: resetsAt) ?? Self.fallbackParser.date(from: resetsAt)
            guard let date else { return nil }
            return "Resets \(Self.display.string(from: date))"
        }
    }
}

/// Compares two URLs loosely — host + path, lowercased, trailing slash
/// trimmed — since the value POST /ingest hands back is the URL as typed,
/// while the Source column ends up holding fetch_post's normalized form
/// (redirects resolved, tracking params dropped). Falls back to substring
/// containment if either string doesn't parse as a URL.
func urlsRoughlyMatch(_ a: String, _ b: String) -> Bool {
    guard !a.isEmpty, !b.isEmpty else { return false }
    if let urlA = URL(string: a), let urlB = URL(string: b),
       let hostA = urlA.host?.lowercased(), let hostB = urlB.host?.lowercased() {
        let pathA = urlA.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathB = urlB.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return hostA.replacingOccurrences(of: "www.", with: "") == hostB.replacingOccurrences(of: "www.", with: "")
            && pathA == pathB
    }
    return a.contains(b) || b.contains(a)
}

/// The paste-a-link screen's "we read <this> off it" line, keyed off the
/// host — mirrors Recipe.sourceLabel but for a URL that isn't saved yet.
func detectedSourceLine(for url: URL) -> String {
    guard let host = url.host?.lowercased(), !host.isEmpty else {
        return "Page — the text will be read"
    }
    if host.contains("instagram.com") {
        return "Instagram reel — caption and owner comment will be read"
    }
    if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("tiktok.com") {
        return "Video — audio and description will be read"
    }
    return "Page — the text will be read"
}

/// A recipe typed straight into the app, sent to POST /api/recipes.
/// Unlike RecipePatch every field is required — there's no existing row
/// to fall back on.
struct RecipeCreate: Encodable {
    var title: String
    var ingredients: [String]
    var steps: [String]
    var course: String
    var tags: [String]
    var notes: String
}

/// A recipebox:// deep link, e.g. from a Shortcuts action.
enum DeepLinkRoute: Equatable {
    case pantry
    case surprise
    case have([String])
}

/// The whole tag vocabulary, on purpose — kept short and closed rather than
/// letting every recipe accumulate its own free-form set. Filtering and the
/// Add/Edit forms only ever offer these; there's no way to type a new one in.
let recipeTags = ["mom's recipes", "veg", "non-veg", "dessert", "high protein", "airfryer"]

/// Only applies when no "have" ingredients are selected — pantry-match
/// score always wins when it's active, same as before.
enum SortOption: String, CaseIterable {
    case recent = "Recent"
    case az = "A–Z"
    case za = "Z–A"
}

/// The list screen's grid/list toggle. Persisted locally (not synced to the
/// server — this is a per-device display preference, not app data).
enum ViewMode: String {
    case list, grid
}

/// Equatable so that matchesByID, which updateVisible() rewrites on every
/// pass, only notifies observers when a recipe's fit actually changed —
/// otherwise every keystroke invalidates every visible card.
struct RecipeMatch: Equatable {
    let score: Double
    let missingCount: Int
    let fullyCovered: Bool

    var label: String {
        if fullyCovered { return "Best fit" }
        if missingCount == 0 { return "\(Int((score * 100).rounded()))% fit" }
        return "\(Int((score * 100).rounded()))% fit · \(missingCount) missing"
    }
}

private let staples: Set<String> = ["salt", "water", "oil", "pepper", "black pepper", "sugar"]

/// Cuts and shapes of a grocery item, not their own pantry entries.
private let pantryForms: Set<String> = [
    "lollipop", "lollipops",
    "breast", "breasts",
    "thigh", "thighs",
    "wing", "wings",
    "drumstick", "drumsticks",
    "tender", "tenders", "tenderloin",
    "fillet", "filet", "fillets",
    "cutlet", "cutlets",
    "chop", "chops",
    "loin", "shoulder", "shank", "belly",
    "nugget", "nuggets",
    "cube", "cubes",
    "strip", "strips",
    "chunk", "chunks",
    "bite", "bites",
    "boneless", "skinless",
    "ground", "whole",
    "leg", "legs",
]

func collapsePantryItems(_ items: [String]) -> [String] {
    var seen = Set<String>()
    var found: [String] = []
    for item in items {
        let name = collapsePantryName(item)
        guard !name.isEmpty, !seen.contains(name) else { continue }
        seen.insert(name)
        found.append(name)
    }
    return found
}

func collapsePantryName(_ name: String) -> String {
    let words = name.lowercased().split { !$0.isLetter }.map(String.init).filter { !$0.isEmpty }
    let core = words.filter { !pantryForms.contains($0) }
    let kept = core.isEmpty ? words : core
    return kept.joined(separator: " ")
}

/// One ingredient line split into a leading quantity (if the text starts
/// with one) and the rest, so the UI can call out amounts clearly.
struct IngredientLine {
    let quantity: String?
    let text: String
}

private let ingredientUnits: Set<String> = [
    "cup", "cups", "tbsp", "tsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
    "g", "gram", "grams", "kg", "ml", "l", "litre", "litres", "liter", "liters",
    "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds",
    "clove", "cloves", "slice", "slices", "pinch", "pinches",
    "can", "cans", "pack", "packs", "packet", "packets",
    "piece", "pieces", "pc", "pcs", "handful", "handfuls",
]

func splitIngredientQuantity(_ line: String) -> IngredientLine {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let words = trimmed.split(separator: " ").map(String.init)
    guard let first = words.first, looksLikeQuantityToken(first) else {
        return IngredientLine(quantity: nil, text: trimmed)
    }

    var quantityParts = [first]
    var consumed = 1
    if words.count > 1 {
        let second = words[1].trimmingCharacters(in: .punctuationCharacters).lowercased()
        if ingredientUnits.contains(second) {
            quantityParts.append(words[1])
            consumed = 2
        }
    }

    let rest = words.dropFirst(consumed)
        .joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    guard !rest.isEmpty else {
        return IngredientLine(quantity: nil, text: trimmed)
    }
    return IngredientLine(quantity: quantityParts.joined(separator: " "), text: rest)
}

private func looksLikeQuantityToken(_ token: String) -> Bool {
    let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    guard !cleaned.isEmpty else { return false }
    // "2", "1/2", "2.5", "2-3", "1¼" — a leading number, optionally a
    // fraction glyph, optionally one more number after a separator.
    let pattern = "^[0-9¼½¾⅓⅔⅛⅜]+([\\/.\\-][0-9]+)?$"
    return cleaned.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - Serving-size scaling

private let fractionGlyphValues: [Character: Double] = [
    "¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "⅛": 0.125, "⅜": 0.375,
]

/// Common cooking fractions to snap a scaled result back to, so "1/3 cup
/// × 1.5" reads as "½ cup" instead of "0.5 cup" or "0.4999999 cup".
private let fractionGlyphsByValue: [(Double, String)] = [
    (0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.375, "⅜"),
    (0.5, "½"), (0.625, "⅝"), (2.0 / 3, "⅔"), (0.75, "¾"), (0.875, "⅞"),
]

/// Parses a leading quantity token into a number. Explicitly refuses a
/// range ("2-3") rather than guessing which side to scale — the caller
/// leaves those untouched instead of silently showing something wrong.
func parseQuantityNumber(_ token: String) -> Double? {
    let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    guard !cleaned.isEmpty, !cleaned.contains("-") else { return nil }

    if cleaned.contains("/") {
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    var rest = Substring(cleaned)
    var whole = 0.0
    var hasWhole = false
    var numStr = ""
    while let c = rest.first, c.isNumber || c == "." {
        numStr.append(c)
        rest.removeFirst()
    }
    if !numStr.isEmpty {
        whole = Double(numStr) ?? 0
        hasWhole = true
    }

    if let glyph = rest.first, let fractionValue = fractionGlyphValues[glyph] {
        return whole + fractionValue
    }
    return hasWhole ? whole : nil
}

/// The inverse of parseQuantityNumber: a scaled number back into a string
/// that reads naturally in a recipe ("1½" rather than "1.5", "3" rather
/// than "3.00").
func formatQuantityNumber(_ value: Double) -> String {
    guard value > 0 else { return "0" }
    let whole = floor(value)
    let fraction = value - whole

    if fraction < 0.02 {
        return String(Int(whole))
    }
    if fraction > 0.98 {
        return String(Int(whole) + 1)
    }
    for (fractionValue, glyph) in fractionGlyphsByValue where abs(fraction - fractionValue) < 0.03 {
        return whole > 0 ? "\(Int(whole))\(glyph)" : glyph
    }
    return String(format: "%.2g", value)
}

/// Scales the leading number in an already-split quantity ("2 cups" →
/// "3 cups" at ×1.5), leaving the unit/rest untouched. Quantities that
/// don't start with a parseable number (ranges, "a pinch") pass through
/// unscaled rather than being guessed at.
func scaledQuantity(_ quantity: String, by scale: Double) -> String {
    guard scale != 1.0 else { return quantity }
    let words = quantity.split(separator: " ")
    guard let first = words.first, let value = parseQuantityNumber(String(first)) else { return quantity }
    let rest = words.dropFirst().joined(separator: " ")
    let formatted = formatQuantityNumber(value * scale)
    return rest.isEmpty ? formatted : "\(formatted) \(rest)"
}

func stem(_ name: String) -> String {
    if name.hasSuffix("chillies") { return String(name.dropLast(2)) }
    if name.hasSuffix("ies"), name.count > 4 { return String(name.dropLast(3)) + "y" }
    if name.hasSuffix("s"), !name.hasSuffix("ss"), name.count > 3 { return String(name.dropLast()) }
    return name
}

func namesMatch(_ left: String, _ right: String) -> Bool {
    left == right || left.contains(right) || right.contains(left) || stem(left) == stem(right)
}

/// How much of this recipe's core (non-staple) ingredients are covered by
/// "what I have". Unlike the old ingredient-search behavior, marking more
/// pantry items never hides a recipe — it only ever raises recipes' scores
/// and shrinks their missing list, the way SuperCook-style matching works.
func matchRecipe(_ recipe: Recipe, have: [String]) -> RecipeMatch? {
    guard !have.isEmpty else { return nil }
    let core = recipe.pantry.filter { !staples.contains($0) }
    let missing = core.filter { item in !have.contains(where: { namesMatch(item, $0) }) }
    let total = max(core.count, 1)
    let matched = core.count - missing.count
    return RecipeMatch(
        score: Double(matched) / Double(total),
        missingCount: missing.count,
        fullyCovered: !core.isEmpty && missing.isEmpty
    )
}

/// The ingredients from `recipe.pantry` not covered by `have` — used both to
/// sort (closest fit first) and to call out what's missing on the detail
/// view.
func missingIngredients(_ recipe: Recipe, have: [String]) -> [String] {
    let core = recipe.pantry.filter { !staples.contains($0) }
    return core.filter { item in !have.contains(where: { namesMatch(item, $0) }) }
}
