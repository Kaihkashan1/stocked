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

struct Recipe: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let servings: String?
    let ingredients: [String]
    let steps: [String]
    let source: String
    let caption: String
    let confidence: String
    let thumbnail: String
    let savedAt: String?
    let cuisine: String
    let meal: String
    let time: String?
    let tags: [String]
    let pantry: [String]
    let favorite: Bool
    let notes: String
    /// Lowercased blob used for search so we do not rebuild it on every keystroke.
    let searchBlob: String

    static func == (lhs: Recipe, rhs: Recipe) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, servings, ingredients, steps, source, caption, confidence, thumbnail, cuisine, meal, time, tags, pantry, favorite, notes
        case savedAt = "saved_at"
    }

    /// Memberwise init for building a locally-modified copy (optimistic
    /// favorite toggles) without a round trip through Codable.
    init(
        id: Int, title: String, servings: String?, ingredients: [String], steps: [String],
        source: String, caption: String, confidence: String, thumbnail: String, savedAt: String?,
        cuisine: String, meal: String, time: String?, tags: [String], pantry: [String],
        favorite: Bool, notes: String, searchBlob: String
    ) {
        self.id = id
        self.title = title
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.source = source
        self.caption = caption
        self.confidence = confidence
        self.thumbnail = thumbnail
        self.savedAt = savedAt
        self.cuisine = cuisine
        self.meal = meal
        self.time = time
        self.tags = tags
        self.pantry = pantry
        self.favorite = favorite
        self.notes = notes
        self.searchBlob = searchBlob
    }

    func withFavorite(_ value: Bool) -> Recipe {
        Recipe(
            id: id, title: title, servings: servings, ingredients: ingredients, steps: steps,
            source: source, caption: caption, confidence: confidence, thumbnail: thumbnail,
            savedAt: savedAt, cuisine: cuisine, meal: meal, time: time, tags: tags, pantry: pantry,
            favorite: value, notes: notes, searchBlob: searchBlob
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        servings = try container.decodeIfPresent(String.self, forKey: .servings)
        ingredients = try container.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail) ?? ""
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine) ?? "Uncategorized"
        meal = try container.decodeIfPresent(String.self, forKey: .meal) ?? "other"
        time = try container.decodeIfPresent(String.self, forKey: .time)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        pantry = collapsePantryItems(try container.decodeIfPresent([String].self, forKey: .pantry) ?? [])
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        searchBlob = ([title, cuisine, meal] + tags + ingredients).joined(separator: " ").lowercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(servings, forKey: .servings)
        try container.encode(ingredients, forKey: .ingredients)
        try container.encode(steps, forKey: .steps)
        try container.encode(source, forKey: .source)
        try container.encode(caption, forKey: .caption)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encode(cuisine, forKey: .cuisine)
        try container.encode(meal, forKey: .meal)
        try container.encodeIfPresent(time, forKey: .time)
        try container.encode(tags, forKey: .tags)
        try container.encode(pantry, forKey: .pantry)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(notes, forKey: .notes)
    }

    var mealLabel: String {
        switch meal {
        case "breakfast": "Breakfast"
        case "lunch": "Lunch"
        case "dinner": "Dinner"
        case "snack": "Snack"
        case "dessert": "Dessert"
        case "drink": "Drink"
        default: "Other"
        }
    }

    var sourceURL: URL? {
        URL(string: source)
    }
}

/// Partial edit sent to PATCH /api/recipes/{id}. Optional properties are
/// synthesized with encodeIfPresent, so an unset field is simply omitted
/// from the request body — the server leaves it untouched.
struct RecipePatch: Encodable {
    var title: String?
    var servings: String?
    var ingredients: [String]?
    var steps: [String]?
    var favorite: Bool?
    var notes: String?
    var tags: [String]?
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

/// A recipe typed straight into the app, sent to POST /api/recipes.
/// Unlike RecipePatch every field is required — there's no existing row
/// to fall back on.
struct RecipeCreate: Encodable {
    var title: String
    var servings: String?
    var ingredients: [String]
    var steps: [String]
    var cuisine: String
    var meal: String
    var time: String?
    var tags: [String]
    var notes: String
}

/// A recipebox:// deep link, e.g. from a Shortcuts action.
enum DeepLinkRoute: Equatable {
    case pantry
    case surprise
    case have([String])
}

/// Only applies when no "have" ingredients are selected — pantry-match
/// score always wins when it's active, same as before.
enum SortOption: String, CaseIterable {
    case recent = "Recent"
    case az = "A–Z"
    case za = "Z–A"
}

struct RecipeMatch {
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
/// sort (closest fit first) and to prefill "add missing to shopping list".
func missingIngredients(_ recipe: Recipe, have: [String]) -> [String] {
    let core = recipe.pantry.filter { !staples.contains($0) }
    return core.filter { item in !have.contains(where: { namesMatch(item, $0) }) }
}
