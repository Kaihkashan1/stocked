import Foundation

struct RecipesResponse: Codable {
    let recipes: [Recipe]
    let pantry: [PantryGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try container.decode([Recipe].self, forKey: .recipes)
        pantry = try container.decodeIfPresent([PantryGroup].self, forKey: .pantry) ?? []
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

    enum CodingKeys: String, CodingKey {
        case id, title, servings, ingredients, steps, source, caption, confidence, thumbnail, cuisine, meal, time, tags, pantry
        case savedAt = "saved_at"
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
        pantry = try container.decodeIfPresent([String].self, forKey: .pantry) ?? []
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

    var thumbnailURL: URL? {
        URL(string: thumbnail)
    }

    var sourceURL: URL? {
        URL(string: source)
    }
}

struct RecipeMatch {
    let score: Double
    let extraCount: Int

    var label: String {
        if extraCount == 0 { return "Best fit" }
        return "\(Int((score * 100).rounded()))% fit · \(extraCount) extra"
    }
}

private let staples: Set<String> = ["salt", "water", "oil", "pepper", "black pepper", "sugar"]

func stem(_ name: String) -> String {
    if name.hasSuffix("chillies") { return String(name.dropLast(2)) }
    if name.hasSuffix("ies"), name.count > 4 { return String(name.dropLast(3)) + "y" }
    if name.hasSuffix("s"), !name.hasSuffix("ss"), name.count > 3 { return String(name.dropLast()) }
    return name
}

func namesMatch(_ left: String, _ right: String) -> Bool {
    left == right || left.contains(right) || right.contains(left) || stem(left) == stem(right)
}

func matchRecipe(_ recipe: Recipe, have: [String]) -> RecipeMatch? {
    guard !have.isEmpty else { return nil }
    let pantry = recipe.pantry
    for wanted in have {
        if !pantry.contains(where: { namesMatch(wanted, $0) }) {
            return nil
        }
    }
    let core = pantry.filter { !staples.contains($0) }
    let extra = core.filter { item in !have.contains(where: { namesMatch(item, $0) }) }
    let total = max(core.count, 1)
    return RecipeMatch(score: Double(have.count) / Double(total), extraCount: extra.count)
}
