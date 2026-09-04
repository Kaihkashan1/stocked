const I18N = {
  en: {
    personalCollection: "Personal collection",
    recipeBox: "Recipe Box",
    addRecipe: "Add recipe",
    typeItIn: "Type it in",
    fromAPhoto: "From a photo",
    settings: "Settings",
    language: "Language",
    matchDevice: "System",
    english: "English",
    german: "Deutsch",
    languageHint: "Buttons and labels use this language. Recipe titles and steps stay as they were saved.",
    editKey: "Edit key",
    developer: "Developer settings",
    logs: "Logs",
    backup: "backup",
    photoImport: "(photo)",
    noImportLogs: "No imports yet.",
    noMatchingLogs: "No matching logs.",
    couldntLoadLogs: "Couldn't load logs.",
    loadingLogs: "Loading logs…",
    allLogs: "All",
    savedLogs: "Saved",
    errorLogs: "Errors",
    additionalDetails: "Additional details",
    previousLogs: "Previous",
    nextLogs: "Next",
    showMoreLogs: "Show more",
    logsRange: "{start}–{end} of {total}",
    importLimits: "Import limits",
    importsToday: "Imports today",
    importCostThisMonth: "Import cost this month",
    ofCount: "{used} of {limit}",
    resetsAround: "Resets around {time} CET",
    resetsOn: "Resets {date}",
    saveAndReload: "Save and reload",
    server: "Server",
    serverFootnote: "Recipes load from the hosted server. Your Mac does not need to be running.",
    editKeyFootnote: "Only needed to favorite or edit. Same value the Shortcut sends.",
    searchAria: "Search recipes, or mark something you have",
    searchPlaceholder: "Search title, ingredient, tag… or mark what you have",
    filters: "Filters",
    whatIHave: "What I have",
    whatIHaveHint: "Sorts recipes by closest fit. Type an ingredient in the search box above to add one.",
    nothingMarkedYet: "Nothing marked yet.",
    tag: "Tag",
    tags: "Tags",
    source: "Source",
    Instagram: "Instagram",
    YouTube: "YouTube",
    TikTok: "TikTok",
    Link: "Link",
    Photo: "Photo",
    "Typed in": "Typed in",
    favoritesOnly: "Favorites only",
    sort: "Sort",
    recent: "Recent",
    az: "A–Z",
    za: "Z–A",
    resetFilters: "Reset filters",
    offlineBanner: "Offline — showing recipes saved on this device",
    loadingRecipes: "Loading recipes…",
    couldNotLoad: "Could not load recipes.",
    editKeyPrompt:
      "Edit key — same value as RECIPE_BOX_SECRET on the server. Needed to favorite, edit, or delete from here. Leave blank against a dev server with no secret set.",
    couldntSaveHave: "Couldn't save what you have: {error}",
    markAsHave: "Mark as something you have:",
    addQuoted: '+ Add "{item}"',
    filtersCount: "Filters ({count})",
    recipeCountOne: "{n} recipe",
    recipeCountOther: "{n} recipes",
    closestFit: "{count} · closest fit to what you have first",
    noMatch: "No recipes match those filters yet.",
    favorite: "Favorite",
    bestFit: "Best fit",
    fitMissing: "{pct}% fit · {n} missing",
    fitPct: "{pct}% fit",
    originalPost: "Original post",
    notes: "Notes",
    missingFromHaveOne: "Missing {n} ingredient from what you have: {list}",
    missingFromHaveOther: "Missing {n} ingredients from what you have: {list}",
    haveEverything: "You have everything for this.",
    close: "Close",
    edit: "Edit",
    deleteRecipe: "Delete recipe",
    ingredients: "Ingredients",
    steps: "Steps",
    noneListed: "None listed",
    servings: "{n} servings",
    cancel: "Cancel",
    editRecipe: "Edit recipe",
    title: "Title",
    servingsLabel: "Servings",
    ingredientsOnePerLine: "Ingredients — one per line, or ## Section for parts",
    stepsOnePerLine: "Steps — one per line",
    tags: "Tags",
    newTag: "New tag",
    addTag: "Add tag",
    save: "Save",
    saving: "Saving…",
    addRecipeTitle: "Add recipe",
    photoPrefillHint: "Read from your photo — check it over before saving.",
    meal: "Meal",
    time: "Time",
    titleEmpty: "Title can't be empty.",
    couldntSave: "Couldn't save: {error}",
    couldntDelete: "Couldn't delete: {error}",
    deleteConfirm: "Delete this recipe?\n\nThis removes it from your box. This can't be undone.",
    readingRecipe: "Reading the recipe…",
    couldntReadPhoto: "Couldn't read that photo: {error}",
    couldNotProcessPhoto: "Could not process that photo.",
    couldNotReadPhoto: "Could not read that photo.",
    exampleFour: "e.g. 4",
    exampleTime: "e.g. 20 min",
    course: "Course",
    "Main course": "Main course",
    Appetizers: "Appetizers",
    Desserts: "Desserts",
    Dips: "Dips",
    Breakfast: "Breakfast",
    Lunch: "Lunch",
    Dinner: "Dinner",
    Snack: "Snack",
    Dessert: "Dessert",
    Drink: "Drink",
    Other: "Other",
    Ingredients: "Ingredients",
    Produce: "Produce",
    "Dairy & eggs": "Dairy & eggs",
    "Meat & seafood": "Meat & seafood",
    "Grains & cupboard": "Grains & cupboard",
    "Grains & pantry": "Grains & pantry",
    "Condiments & spices": "Condiments & spices",
    "mom's recipes": "mom's recipes",
    veg: "veg",
    "non-veg": "non-veg",
    dessert: "dessert",
    "high protein": "high protein",
    airfryer: "airfryer",
  },
};

function t(key, vars) {
  const table = I18N.en || {};
  let text = Object.prototype.hasOwnProperty.call(table, key) ? table[key] : key;
  if (vars) {
    for (const [name, value] of Object.entries(vars)) {
      text = text.replaceAll(`{${name}}`, String(value));
    }
  }
  return text;
}

// Only the six fixed suggested tags (RECIPE_TAGS, defined in app.js) have
// real translations — a free-text custom tag must never be looked up
// against the whole app-wide string table, or a tag that happens to match
// an unrelated UI key (e.g. "high", "notes", "close") would silently
// render as that unrelated translated string instead of the user's tag.
function tTag(tag) {
  if (typeof RECIPE_TAGS !== "undefined" && RECIPE_TAGS.includes(tag)) {
    return t(tag);
  }
  return tag;
}

function applyStaticI18n() {
  document.documentElement.lang = "en";
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    el.textContent = t(el.getAttribute("data-i18n"));
  });
  document.querySelectorAll("[data-i18n-html]").forEach((el) => {
    el.innerHTML = t(el.getAttribute("data-i18n-html"));
  });
  document.querySelectorAll("[data-i18n-placeholder]").forEach((el) => {
    el.placeholder = t(el.getAttribute("data-i18n-placeholder"));
  });
  document.querySelectorAll("[data-i18n-aria]").forEach((el) => {
    el.setAttribute("aria-label", t(el.getAttribute("data-i18n-aria")));
  });
  const title = document.querySelector("title");
  if (title) title.textContent = t("recipeBox");
}
