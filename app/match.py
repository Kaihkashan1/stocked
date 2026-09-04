"""Turn raw ingredient lines into pantry names, and rank recipes by what you have."""

from __future__ import annotations

import re

# Heading-only line ("Sauce:") or "Sauce: yogurt" — used so the UI can
# show a section title above the items without counting the heading as
# an ingredient for pantry matching.
_SECTION_HEADING = re.compile(r"^([^:]{1,40}):\s*$")
_SECTION_PREFIX = re.compile(r"^([^:]{1,40}):\s+(.+)$")


def looks_like_section_name(name: str) -> bool:
    text = (name or "").strip()
    if not text or len(text) > 40:
        return False
    if any(ch.isdigit() for ch in text):
        return False
    words = text.split()
    return 1 <= len(words) <= 4


def split_ingredient_section(line: str) -> tuple[str | None, str | None]:
    """Return (section, item). item is None for a heading-only line."""
    text = (line or "").strip()
    if not text:
        return None, ""
    heading = _SECTION_HEADING.match(text)
    if heading and looks_like_section_name(heading.group(1)):
        return heading.group(1).strip(), None
    prefixed = _SECTION_PREFIX.match(text)
    if prefixed and looks_like_section_name(prefixed.group(1)):
        return prefixed.group(1).strip(), prefixed.group(2).strip()
    return None, text

UNITS = {
    "cup",
    "cups",
    "tbsp",
    "tsp",
    "teaspoon",
    "teaspoons",
    "tablespoon",
    "tablespoons",
    "g",
    "gram",
    "grams",
    "kg",
    "ml",
    "l",
    "litre",
    "liter",
    "oz",
    "ounce",
    "ounces",
    "lb",
    "pound",
    "clove",
    "cloves",
    "slice",
    "slices",
    "pinch",
    "pinches",
    "can",
    "cans",
    "pack",
    "packet",
    "piece",
    "pieces",
    "handful",
}
PREP = {
    "chopped",
    "finely",
    "roughly",
    "minced",
    "sliced",
    "diced",
    "pulsed",
    "cooked",
    "fresh",
    "freshly",
    "crushed",
    "mixed",
    "grated",
    "optional",
    "large",
    "small",
    "medium",
    "ripe",
    "to",
    "taste",
    "as",
    "needed",
    "or",
    "and",
    "for",
    "the",
    "a",
    "an",
    "of",
    "into",
    "with",
}
# Cuts and shapes of a grocery item, not their own pantry entries.
# "chicken lollipop" and "chicken breast" should both be "chicken".
FORMS = {
    "lollipop",
    "lollipops",
    "breast",
    "breasts",
    "thigh",
    "thighs",
    "wing",
    "wings",
    "drumstick",
    "drumsticks",
    "tender",
    "tenders",
    "tenderloin",
    "fillet",
    "filet",
    "fillets",
    "cutlet",
    "cutlets",
    "chop",
    "chops",
    "loin",
    "shoulder",
    "shank",
    "belly",
    "nugget",
    "nuggets",
    "cube",
    "cubes",
    "strip",
    "strips",
    "chunk",
    "chunks",
    "bite",
    "bites",
    "boneless",
    "skinless",
    "ground",
    "whole",
    "leg",
    "legs",
}
STAPLES = {"salt", "water", "oil", "pepper", "black pepper", "sugar"}


def canonical_ingredient(line: str) -> str:
    text = (line or "").lower()
    text = re.sub(r"\([^)]*\)", " ", text)
    text = re.split(r"\bor\b", text, maxsplit=1)[0]
    text = text.replace(",", " ")
    text = re.sub(r"[\d¼½¾⅓⅔⅛⅜/.\-]+", " ", text)
    words = [word for word in re.findall(r"[a-z]+", text) if word not in UNITS and word not in PREP]
    core = [word for word in words if word not in FORMS]
    if core:
        words = core
    if not words:
        return ""
    return _singularize(" ".join(words))


def pantry_items(ingredients: list[str]) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for line in ingredients:
        _section, item = split_ingredient_section(line)
        if item is None:
            continue
        name = canonical_ingredient(item)
        if not name or name in seen:
            continue
        seen.add(name)
        found.append(name)
    return found


def core_items(pantry: list[str]) -> list[str]:
    return [item for item in pantry if item not in STAPLES]


def match_score(pantry: list[str], selected: list[str]) -> dict | None:
    """Require every selected item to appear. Higher score = fewer extra ingredients."""
    if not selected:
        return None
    core = core_items(pantry) or pantry
    haystack = set(pantry)
    for wanted in selected:
        if not any(_names_match(wanted, have) for have in haystack):
            return None
    extra = [item for item in core if not any(_names_match(item, wanted) for wanted in selected)]
    total = max(len(core), 1)
    score = round(len(selected) / total, 4)
    return {
        "score": score,
        "percent": round(score * 100),
        "extra": extra,
        "extra_count": len(extra),
    }


def _names_match(left: str, right: str) -> bool:
    if left == right:
        return True
    left_stem = _singularize(left)
    right_stem = _singularize(right)
    if left_stem == right_stem:
        return True
    return (
        left in right.split()
        or right in left.split()
        or left_stem in right_stem.split()
        or right_stem in left_stem.split()
        or left in right
        or right in left
    )


# Longer / more specific keywords first within each group.
# "fish sauce" is a condiment, so that group is checked before Seafood.
_CATEGORY_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    (
        "Sauces & condiments",
        (
            "soy sauce",
            "fish sauce",
            "oyster sauce",
            "hot sauce",
            "chilli sauce",
            "chili sauce",
            "tomato paste",
            "tomato puree",
            "coconut milk",
            "coconut cream",
            "worcestershire",
            "vinegar",
            "ketchup",
            "mayonnaise",
            "mayo",
            "mustard",
            "sriracha",
            "hoisin",
            "pesto",
            "stock",
            "broth",
            "bouillon",
            "honey",
            "maple",
            "jam",
            "pickle",
            "chutney",
            "tahini",
            "miso",
            "passata",
            "salsa",
            "wine",
            "beer",
        ),
    ),
    (
        "Meat",
        (
            "chicken",
            "mutton",
            "lamb",
            "goat",
            "beef",
            "pork",
            "bacon",
            "ham",
            "sausage",
            "turkey",
            "duck",
            "keema",
            "mince",
            "pepperoni",
            "salami",
            "steak",
            "ribs",
            "meatball",
            "prosciutto",
        ),
    ),
    (
        "Seafood",
        (
            "salmon",
            "tuna",
            "prawn",
            "shrimp",
            "crab",
            "lobster",
            "squid",
            "calamari",
            "mussel",
            "clam",
            "anchovy",
            "sardine",
            "cod",
            "tilapia",
            "seafood",
            "fish",
        ),
    ),
    (
        "Dairy & eggs",
        (
            "cream cheese",
            "sour cream",
            "condensed milk",
            "buttermilk",
            "mozzarella",
            "parmesan",
            "cheddar",
            "ricotta",
            "yogurt",
            "yoghurt",
            "paneer",
            "cheese",
            "butter",
            "cream",
            "ghee",
            "curd",
            "milk",
            "egg",
        ),
    ),
    (
        "Nuts & seeds",
        (
            "peanut butter",
            "peanut",
            "almond",
            "cashew",
            "walnut",
            "pistachio",
            "pine nut",
            "sesame",
            "sunflower",
            "chia",
            "flax",
        ),
    ),
    (
        "Herbs & spices",
        (
            "garam masala",
            "curry leaf",
            "curry leaves",
            "chilli powder",
            "chili powder",
            "asafoetida",
            "cardamom",
            "cinnamon",
            "coriander",
            "turmeric",
            "paprika",
            "oregano",
            "rosemary",
            "thyme",
            "basil",
            "mint",
            "parsley",
            "dill",
            "cumin",
            "fennel",
            "saffron",
            "nutmeg",
            "clove",
            "bay",
            "masala",
            "hing",
            "methi",
            "herb",
        ),
    ),
    (
        "Grains & pasta",
        (
            "breadcrumb",
            "spaghetti",
            "macaroni",
            "couscous",
            "tortilla",
            "semolina",
            "quinoa",
            "barley",
            "millet",
            "noodle",
            "pasta",
            "flour",
            "maida",
            "atta",
            "bread",
            "poha",
            "rava",
            "oat",
            "rice",
            "naan",
            "roti",
            "pita",
            "bun",
            "wrap",
        ),
    ),
    (
        "Legumes",
        (
            "chickpea",
            "kidney bean",
            "black bean",
            "lentil",
            "edamame",
            "tempeh",
            "hummus",
            "rajma",
            "besan",
            "moong",
            "chana",
            "masoor",
            "tofu",
            "soya",
            "soy",
            "dal",
            "daal",
            "urad",
            "gram",
        ),
    ),
    (
        "Fruit",
        (
            "pomegranate",
            "strawberry",
            "pineapple",
            "cranberry",
            "avocado",
            "coconut",
            "banana",
            "orange",
            "lemon",
            "lime",
            "mango",
            "apple",
            "grape",
            "raisin",
            "date",
            "peach",
            "pear",
            "fig",
            "berry",
        ),
    ),
    (
        "Vegetables",
        (
            "spring onion",
            "bell pepper",
            "green bean",
            "cauliflower",
            "mushroom",
            "aubergine",
            "eggplant",
            "brinjal",
            "capsicum",
            "zucchini",
            "cucumber",
            "spinach",
            "cabbage",
            "broccoli",
            "pumpkin",
            "beetroot",
            "shallot",
            "lettuce",
            "celery",
            "carrot",
            "potato",
            "tomato",
            "garlic",
            "ginger",
            "onion",
            "chilli",
            "chili",
            "chilly",
            "bhindi",
            "okra",
            "leek",
            "kale",
            "corn",
            "pea",
            "bean",
        ),
    ),
]


def pantry_category(name: str) -> str:
    text = (name or "").strip().lower()
    if not text:
        return "Other"
    for category, keywords in _CATEGORY_KEYWORDS:
        for keyword in keywords:
            if _keyword_in_name(text, keyword):
                return category
    return "Other"


def grouped_pantry(items: list[str]) -> list[dict]:
    buckets: dict[str, list[str]] = {}
    for item in items:
        buckets.setdefault(pantry_category(item), []).append(item)
    order = [category for category, _ in _CATEGORY_KEYWORDS] + ["Other"]
    groups = []
    for category in order:
        names = sorted(buckets.get(category) or [], key=str.lower)
        if names:
            groups.append({"category": category, "items": names})
    return groups


def _keyword_in_name(name: str, keyword: str) -> bool:
    if " " in keyword:
        return keyword in name
    return re.search(rf"\b{re.escape(keyword)}s?\b", name) is not None


def _singularize(name: str) -> str:
    if name.endswith("chillies"):
        return name[:-2]
    if name.endswith("ies") and len(name) > 4:
        return name[:-3] + "y"
    if name.endswith("oes") and len(name) > 4:
        return name[:-2]
    if name.endswith("sses"):
        return name
    if name.endswith("s") and not name.endswith("ss") and len(name) > 3:
        return name[:-1]
    return name
