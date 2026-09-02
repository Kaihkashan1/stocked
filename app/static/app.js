const STAPLES = new Set(["salt", "water", "oil", "pepper", "black pepper", "sugar"]);

// Suggested chips. Gemini still picks from this list; add/edit can type more.
const RECIPE_TAGS = ["mom's recipes", "veg", "non-veg", "dessert", "high protein", "airfryer"];
const MAX_RECIPE_TAG_LENGTH = 32;
const MAX_RECIPE_TAGS = 24;
const COURSES = ["Main course", "Appetizers", "Desserts", "Dips"];

function courseFromMeal(meal) {
  if (meal === "dessert") return "Desserts";
  if (meal === "snack") return "Appetizers";
  return "Main course";
}

// Shared by courseChipsHtml (single-select) and existingTagChips
// (multi-select) below — the only thing that varies between a course chip
// and a tag chip is the CSS class, the data-* attribute name, which item is
// "active", and how its label is looked up.
function chipButtonHtml({ className, action, dataAttr, value, active, label }) {
  return `<button class="${className}${active ? " active" : ""}" type="button" data-action="${action}" data-${dataAttr}="${escapeAttr(value)}">${escapeHtml(label)}</button>`;
}

function courseChipsHtml(selected, action) {
  return COURSES.map((course) =>
    chipButtonHtml({ className: "chip", action, dataAttr: "course", value: course, active: course === selected, label: t(course) })
  ).join("");
}

function setCourseSelection(which, course) {
  const input = document.getElementById(`${which}-course`);
  const chips = document.getElementById(`${which}-course-chips`);
  if (!input || !chips || !COURSES.includes(course)) return;
  input.value = course;
  chips.innerHTML = courseChipsHtml(course, which === "edit" ? "pick-edit-course" : "pick-add-course");
}

// Mirrors app/match.py's UNITS and Models.swift's ingredientUnits, so a
// quantity gets called out the same way on every surface.
const INGREDIENT_UNITS = new Set([
  "cup", "cups", "tbsp", "tsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
  "g", "gram", "grams", "kg", "ml", "l", "litre", "litres", "liter", "liters",
  "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds",
  "clove", "cloves", "slice", "slices", "pinch", "pinches",
  "can", "cans", "pack", "packs", "packet", "packets",
  "piece", "pieces", "pc", "pcs", "handful", "handfuls",
]);

const SECRET_KEY = "recipeBox.secret";
const HAVE_KEY = "recipeBox.have";
const RECIPES_CACHE_KEY = "recipeBox.recipesCache";

const state = {
  recipes: [],
  pantryGroups: [],
  tags: new Set(),
  knownTags: [],
  query: "",
  have: loadHave(),
  favoritesOnly: false,
  sort: "recent",
  openRecipeId: null,
  editingId: null,
  addingRecipe: false,
  usage: null,
  devSettingsOpen: false,
};

const els = {
  search: document.getElementById("search"),
  searchSuggest: document.getElementById("search-suggest"),
  tagFilters: document.getElementById("tag-filters"),
  haveChips: document.getElementById("have-chips"),
  favoritesToggle: document.getElementById("favorites-toggle"),
  filtersBtn: document.getElementById("filters-btn"),
  filtersPanel: document.getElementById("filters-panel"),
  filtersReset: document.getElementById("filters-reset"),
  grid: document.getElementById("grid"),
  status: document.getElementById("status"),
  drawer: document.getElementById("drawer"),
  detail: document.getElementById("recipe-detail"),
  settingsBtn: document.getElementById("settings-btn"),
  addRecipeBtn: document.getElementById("add-recipe-btn"),
  addRecipeMenu: document.getElementById("add-recipe-menu"),
  photoInput: document.getElementById("photo-input"),
  offlineBanner: document.getElementById("offline-banner"),
};

function setOfflineBanner(show) {
  if (!els.offlineBanner) return;
  els.offlineBanner.hidden = !show;
}

function applyRecipePayload(data) {
  state.recipes = (data.recipes || []).map((recipe) => {
    recipe.searchBlob = computeSearchBlob(recipe);
    return recipe;
  });
  state.pantryGroups = Array.isArray(data.pantry) ? data.pantry : [];
}

function loadCachedRecipes() {
  try {
    const raw = localStorage.getItem(RECIPES_CACHE_KEY);
    if (!raw) return false;
    applyRecipePayload(JSON.parse(raw));
    renderFilters();
    renderGrid();
    maybeOpenFromHash();
    return state.recipes.length > 0;
  } catch {
    return false;
  }
}

function persistRecipesCache(data) {
  try {
    localStorage.setItem(RECIPES_CACHE_KEY, JSON.stringify({
      recipes: data.recipes || [],
      pantry: Array.isArray(data.pantry) ? data.pantry : [],
    }));
  } catch {
    // quota — browsing still works from memory this session
  }
}

async function load({ silent = false } = {}) {
  const hadCache = state.recipes.length > 0;
  if (!silent && !hadCache) {
    els.status.textContent = t("loadingRecipes");
  }
  try {
    const response = await fetch("/api/recipes", { cache: "no-store" });
    if (!response.ok) {
      if (!hadCache) els.status.textContent = t("couldNotLoad");
      else setOfflineBanner(true);
      return;
    }
    const data = await response.json();
    applyRecipePayload(data);
    persistRecipesCache(data);
    setOfflineBanner(false);
    renderFilters();
    renderGrid();
    maybeOpenFromHash();
    await fetchHave();
    renderFilters();
    renderGrid();
  } catch {
    if (hadCache) {
      setOfflineBanner(true);
    } else {
      els.status.textContent = t("couldNotLoad");
    }
  }
}

// ---------- auth / API ----------

function authHeaders() {
  const secret = (localStorage.getItem(SECRET_KEY) || "").trim();
  return secret ? { "X-Recipe-Box-Key": secret } : {};
}

// A FastAPI HTTPException's {"detail": "..."} body is usually a real,
// actionable message (e.g. "Gemini's free daily quota is used up...")
// rather than just a status code — surface it when present.
async function errorForResponse(response) {
  try {
    const body = await response.json();
    if (body && typeof body.detail === "string") return new Error(body.detail);
  } catch {
    // body wasn't JSON, or had no detail field — fall through
  }
  return new Error(`Server returned HTTP ${response.status}`);
}

async function createRecipeRequest(draft) {
  const response = await fetch("/api/recipes", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(draft),
  });
  if (!response.ok) throw await errorForResponse(response);
  return response.json();
}

async function patchRecipe(id, patch) {
  const response = await fetch(`/api/recipes/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(patch),
  });
  if (!response.ok) throw await errorForResponse(response);
  return response.json();
}

async function deleteRecipeRequest(id) {
  const response = await fetch(`/api/recipes/${id}`, { method: "DELETE", headers: authHeaders() });
  if (!response.ok) throw await errorForResponse(response);
  return response.json();
}

function openSettings() {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  state.devSettingsOpen = false;
  renderSettings();
  els.drawer.hidden = false;
  fetchUsage().then((usage) => {
    state.usage = usage;
    if (!els.drawer.hidden && state.addingRecipe === false && state.openRecipeId == null && state.editingId == null) {
      const typed = document.getElementById("settings-secret")?.value;
      renderSettings();
      if (typed != null) {
        const again = document.getElementById("settings-secret");
        if (again) again.value = typed;
      }
    }
  });
}

function renderSettings() {
  els.detail.innerHTML = settingsFormHtml();
}

function formatUsd(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return "$0";
  return "$" + (n === Math.round(n) ? n.toFixed(0) : n.toFixed(2));
}

function appDateLocale() {
  return "en-US";
}

/// Next Gemini free-tier reset: midnight Pacific, shown as a CET clock time
/// — same conversion Settings on iOS uses.
function geminiResetsLabel() {
  const now = new Date();
  const pacificNow = new Date(now.toLocaleString("en-US", { timeZone: "America/Los_Angeles" }));
  const nextPacific = new Date(pacificNow);
  nextPacific.setHours(24, 0, 0, 0);
  const offset = nextPacific.getTime() - pacificNow.getTime();
  const next = new Date(now.getTime() + offset);
  const time = next.toLocaleTimeString(appDateLocale(), {
    timeZone: "Europe/Berlin",
    hour: "numeric",
    minute: "2-digit",
  });
  return t("resetsAround", { time });
}

function apifyResetsLabel(resetsAt) {
  if (!resetsAt) return "";
  const date = new Date(resetsAt);
  if (Number.isNaN(date.getTime())) return "";
  const formatted = date.toLocaleDateString(appDateLocale(), { month: "short", day: "numeric" });
  return t("resetsOn", { date: formatted });
}

async function fetchUsage() {
  try {
    const response = await fetch("/api/usage", { headers: authHeaders() });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

function settingsFormHtml() {
  const secret = localStorage.getItem(SECRET_KEY) || "";
  const usage = state.usage;
  let limitsHtml = "";
  if (usage?.gemini) {
    const geminiPct = usage.gemini.limit ? Math.min(100, (100 * usage.gemini.used) / usage.gemini.limit) : 0;
    let bars = `
      <div class="usage-row">
        <div class="usage-row-head"><span>${escapeHtml(t("importsToday"))}</span><span>${escapeHtml(t("ofCount", { used: usage.gemini.used, limit: usage.gemini.limit }))}</span></div>
        <div class="usage-track"><div class="usage-fill" style="width:${geminiPct}%"></div></div>
        <p class="usage-reset">${escapeHtml(geminiResetsLabel())}</p>
      </div>`;
    if (usage.apify) {
      const apifyPct = usage.apify.limit_usd ? Math.min(100, (100 * usage.apify.used_usd) / usage.apify.limit_usd) : 0;
      const apifyReset = apifyResetsLabel(usage.apify.resets_at);
      bars += `
      <div class="usage-row">
        <div class="usage-row-head"><span>${escapeHtml(t("importCostThisMonth"))}</span><span>${escapeHtml(t("ofCount", { used: formatUsd(usage.apify.used_usd), limit: formatUsd(usage.apify.limit_usd) }))}</span></div>
        <div class="usage-track"><div class="usage-fill" style="width:${apifyPct}%"></div></div>
        ${apifyReset ? `<p class="usage-reset">${escapeHtml(apifyReset)}</p>` : ""}
      </div>`;
    }
    limitsHtml = `<div class="import-limits"><div class="eyebrow">${escapeHtml(t("importLimits"))}</div>${bars}</div>`;
  }
  const chevron = state.devSettingsOpen ? "180deg" : "0deg";
  const devBody = state.devSettingsOpen
    ? `<div class="dev-settings">
        <label class="field">
          <span>${escapeHtml(t("editKey"))}</span>
          <input id="settings-secret" type="password" autocomplete="off" value="${escapeAttr(secret)}" placeholder="${escapeAttr(t("editKey"))}">
          <p class="field-note">${escapeHtml(t("editKeyFootnote"))}</p>
        </label>
        <button class="pill-btn primary" type="button" data-action="save-settings">${escapeHtml(t("saveAndReload"))}</button>
      </div>`
    : "";
  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("close"))}
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(t("settings"))}</h2>
      ${limitsHtml}
      <button class="dev-toggle" type="button" data-action="toggle-developer">
        <span class="eyebrow">${escapeHtml(t("developer"))}</span>
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round" style="transform:rotate(${chevron})"><path d="M6 9l6 6 6-6"></path></svg>
      </button>
      ${devBody}
    </div>`;
}

function saveSettings() {
  const input = document.getElementById("settings-secret");
  if (input) localStorage.setItem(SECRET_KEY, input.value.trim());
  location.reload();
}

// ---------- ingredient quantity emphasis ----------

function looksLikeQuantityToken(token) {
  const cleaned = token.replace(/^[,;]+|[,;]+$/g, "");
  if (!cleaned) return false;
  return /^[0-9¼½¾⅓⅔⅛⅜]+([/.-][0-9]+)?$/.test(cleaned);
}

function splitIngredientQuantity(line) {
  const trimmed = line.trim();
  const words = trimmed.split(/\s+/).filter(Boolean);
  if (!words.length || !looksLikeQuantityToken(words[0])) {
    return { quantity: null, text: trimmed };
  }
  const quantityParts = [words[0]];
  let consumed = 1;
  if (words.length > 1) {
    const second = words[1].replace(/[.,;]+$/, "").toLowerCase();
    if (INGREDIENT_UNITS.has(second)) {
      quantityParts.push(words[1]);
      consumed = 2;
    }
  }
  const rest = words.slice(consumed).join(" ").replace(/^[,\s]+/, "");
  if (!rest) return { quantity: null, text: trimmed };
  return { quantity: quantityParts.join(" "), text: rest };
}

// ---------- pantry ("what I have") ----------

// The pantry syncs through GET/PUT /api/pantry (same one this app's iOS
// counterpart uses) so it matches between devices — it's a real inventory
// now, not a per-session browsing filter. localStorage is kept only as an
// instant-render cache for first paint, before the fetch in load()
// reconciles it against the server.
function loadHave() {
  try {
    const raw = localStorage.getItem(HAVE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function cacheHave() {
  localStorage.setItem(HAVE_KEY, JSON.stringify(state.have));
}

async function fetchHave() {
  try {
    const response = await fetch("/api/pantry");
    if (!response.ok) return;
    const data = await response.json();
    state.have = Array.isArray(data.items) ? data.items : [];
    cacheHave();
  } catch {
    // keep whatever the local cache had
  }
}

async function putHave(items) {
  const response = await fetch("/api/pantry", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ items }),
  });
  if (!response.ok) throw await errorForResponse(response);
  return (await response.json()).items;
}

// Optimistic, like toggleFavorite: flips locally first, pushes the whole
// set, reverts on failure. Used for both the search-box suggestion chips
// and the "What I have" chips in the Filters panel.
async function togglePantry(item) {
  const previous = [...state.have];
  state.have = state.have.includes(item) ? state.have.filter((value) => value !== item) : [...state.have, item];
  cacheHave();
  renderHaveChips();
  renderSearchSuggest();
  renderGrid();
  refreshOpenRecipe();

  try {
    const confirmed = await putHave(state.have);
    state.have = confirmed;
  } catch (err) {
    state.have = previous;
    window.alert(t("couldntSaveHave", { error: err.message }));
  }
  cacheHave();
  renderHaveChips();
  renderSearchSuggest();
  renderGrid();
  refreshOpenRecipe();
}

// A free-text addition — for something you have that isn't derived from any
// recipe (a specific brand, a leftover, whatever). Normalized the same way
// the server does (trimmed, lowercased) so it still matches recipe
// ingredients via namesMatch just like a catalog pick would.
function addHaveItem(raw) {
  const item = raw.trim().toLowerCase();
  if (!item) return;
  if (state.have.some((existing) => existing === item || namesMatch(existing, item))) return;
  ensurePantryGroupContains(item);
  togglePantry(item);
}

// The server re-categorizes on the next full reload; this just keeps a
// freshly-typed custom item from vanishing from "What I have" until then.
function ensurePantryGroupContains(item) {
  if (state.pantryGroups.some((group) => group.items.includes(item))) return;
  let other = state.pantryGroups.find((group) => group.category === "Other");
  if (!other) {
    other = { category: "Other", items: [] };
    state.pantryGroups.push(other);
  }
  other.items.push(item);
  other.items.sort((a, b) => a.localeCompare(b));
}

// True once you've typed something that doesn't already exactly match a
// catalog ingredient or an existing "have" item — that's when "+ Add" is a
// real option rather than a no-op duplicate of selecting an existing chip.
function canAddTypedPantryItem(trimmedNeedle) {
  if (!trimmedNeedle) return false;
  const lower = trimmedNeedle.toLowerCase();
  return !pantryCatalog().concat(state.have).some((item) => item.toLowerCase() === lower);
}

// The "What I have" section of the Filters panel — just the currently
// marked chips (removable), no search of its own. Finding/adding lives in
// the main search box now (see renderSearchSuggest) — no reason for a
// second, separate ingredient search elsewhere in the app.
function renderHaveChips() {
  const selected = groupPantry(state.have);
  els.haveChips.innerHTML = selected.length
    ? pantryGroupsHtml(selected, true)
    : `<span class="status">${escapeHtml(t("nothingMarkedYet"))}</span>`;
}

// The same box you search recipes with also lets you mark something as
// "what I have" — shown as a small suggestion row right under it rather
// than a separate Pantry search, since it's the same underlying question
// ("does this text match an ingredient?") the recipe search is already
// asking. Gated behind actually typing something, same reasoning as the
// old Pantry-tab search: skimming the whole catalog doesn't scale as the
// box grows.
function renderSearchSuggest() {
  const trimmed = state.query.trim();
  if (!trimmed) {
    els.searchSuggest.innerHTML = "";
    els.searchSuggest.hidden = true;
    return;
  }

  const needle = trimmed.toLowerCase();
  const matches = pantryCatalog()
    .filter((item) => !state.have.includes(item) && pantryQueryMatch(item, needle))
    .slice(0, 8);
  const canAdd = canAddTypedPantryItem(trimmed);
  if (!matches.length && !canAdd) {
    els.searchSuggest.innerHTML = "";
    els.searchSuggest.hidden = true;
    return;
  }

  const matchChips = matches
    .map((item) => `<button class="chip toggle" type="button" data-pantry="${escapeAttr(item)}">+ ${escapeHtml(item)}</button>`)
    .join("");
  const addChip = canAdd
    ? `<button class="chip active" type="button" data-action="add-pantry-item" data-item="${escapeAttr(trimmed)}">${escapeHtml(t("addQuoted", { item: trimmed }))}</button>`
    : "";
  els.searchSuggest.innerHTML = `<span class="search-suggest-label">${escapeHtml(t("markAsHave"))}</span>${matchChips}${addChip}`;
  els.searchSuggest.hidden = false;
}

// ---------- filters / recipe grid (existing browse behavior) ----------

function renderFilters() {
  renderHaveChips();

  // Suggested six, tags on recipes, and tags created on add/edit. Select-only.
  const tags = unique([...RECIPE_TAGS, ...state.knownTags, ...state.recipes.flatMap((recipe) => recipe.tags || [])]);
  els.tagFilters.innerHTML = tags
    .map((tag) => {
      const active = state.tags.has(tag);
      return `<button class="chip${active ? " active" : ""}" type="button" data-action="toggle-tag-filter" data-tag="${escapeAttr(tag)}">${escapeHtml(tTag(tag))}${active ? " ×" : ""}</button>`;
    })
    .join("");

  els.favoritesToggle.classList.toggle("active", state.favoritesOnly);

  document
    .querySelectorAll("#sort-options .chip")
    .forEach((chip) => chip.classList.toggle("active", chip.dataset.sort === state.sort));

  const activeCount = [state.tags.size > 0, state.favoritesOnly, state.have.length > 0].filter(Boolean).length;
  els.filtersBtn.classList.toggle("active", activeCount > 0);
  els.filtersBtn.textContent = "";
  els.filtersBtn.append(filtersIcon(), document.createTextNode(activeCount > 0 ? t("filtersCount", { count: activeCount }) : t("filters")));
}

function filtersIcon() {
  const span = document.createElement("span");
  span.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M7 12h10M10 18h4"/></svg>`;
  return span.firstElementChild;
}

function openFilters() {
  els.filtersPanel.hidden = false;
  els.filtersBtn.setAttribute("aria-expanded", "true");
}

function closeFilters() {
  els.filtersPanel.hidden = true;
  els.filtersBtn.setAttribute("aria-expanded", "false");
}

// The recipe drawer's "⋯" menu (Original post / Edit / Delete) — same
// split as the iOS ellipsis menu, with Favorite kept as its own button.
function toggleRecipeMenu() {
  const menu = document.querySelector(".recipe-menu");
  const btn = document.querySelector('[data-action="toggle-recipe-menu"]');
  if (!menu || !btn) return;
  menu.hidden = !menu.hidden;
  btn.setAttribute("aria-expanded", String(!menu.hidden));
}

function closeRecipeMenu() {
  const menu = document.querySelector(".recipe-menu");
  const btn = document.querySelector('[data-action="toggle-recipe-menu"]');
  if (menu) menu.hidden = true;
  if (btn) btn.setAttribute("aria-expanded", "false");
}

function pantryCatalog() {
  return unique(state.recipes.flatMap((recipe) => recipe.pantry || [])).filter(
    (item) => !STAPLES.has(item)
  );
}

function groupPantry(items) {
  if (state.pantryGroups.length) {
    const allowed = new Set(items);
    return state.pantryGroups
      .map((group) => ({
        category: group.category,
        items: group.items.filter((item) => allowed.has(item)),
      }))
      .filter((group) => group.items.length);
  }
  if (!items.length) return [];
  return [{ category: "Ingredients", items: items }];
}

function pantryGroupsHtml(groups, selected) {
  return groups
    .map((group) => {
      const chips = group.items
        .map(
          (item) =>
            `<button class="chip${selected ? " active" : " toggle"}" type="button" data-pantry="${escapeAttr(item)}">${escapeHtml(item)}${selected ? " ×" : ""}</button>`
        )
        .join("");
      return `<div class="pantry-group"><h3 class="pantry-heading">${escapeHtml(t(group.category))}</h3><div class="chips">${chips}</div></div>`;
    })
    .join("");
}

function stem(name) {
  if (name.endsWith("chillies")) return name.slice(0, -2);
  if (name.endsWith("ies") && name.length > 4) return `${name.slice(0, -3)}y`;
  if (name.endsWith("s") && !name.endsWith("ss") && name.length > 3) return name.slice(0, -1);
  return name;
}

function namesMatch(left, right) {
  if (left === right || left.includes(right) || right.includes(left)) return true;
  return stem(left) === stem(right);
}

function pantryQueryMatch(item, needle) {
  if (!needle) return true;
  return item.includes(needle) || needle.includes(item) || namesMatch(item, needle);
}

// How much of this recipe's core (non-staple) ingredients are covered by
// "what I have". Unlike the old ingredient-search behavior, marking more
// pantry items never hides a recipe — it only ever raises recipes' scores
// and shrinks their missing list, the way SuperCook-style matching works.
function recipeMatch(recipe) {
  const pantry = recipe.pantry || [];
  if (!state.have.length) return { score: 0, missing: 0, fullyCovered: false };
  const core = pantry.filter((item) => !STAPLES.has(item));
  const missingItems = core.filter((item) => !state.have.some((have) => namesMatch(item, have)));
  const total = Math.max(core.length, 1);
  const matched = core.length - missingItems.length;
  return { score: matched / total, missing: missingItems.length, fullyCovered: core.length > 0 && missingItems.length === 0 };
}

// The ingredients from `recipe.pantry` you don't have — used both to sort
// the grid (closest fit first) and to call out what's missing on the
// detail view.
function missingIngredients(recipe) {
  const core = (recipe.pantry || []).filter((item) => !STAPLES.has(item));
  return core.filter((item) => !state.have.some((have) => namesMatch(item, have)));
}

// Computed once per recipe (on load, and again after any edit that could
// change these fields) rather than rebuilt on every filtered() call — the
// same tradeoff Models.swift makes on iOS (see Recipe.searchBlob there).
function computeSearchBlob(recipe) {
  return [recipe.title, recipe.course, ...(recipe.tags || []), ...(recipe.ingredients || [])].join(" ").toLowerCase();
}

function filtered() {
  const query = state.query.trim().toLowerCase();
  const rows = [];
  for (const recipe of state.recipes) {
    if (state.favoritesOnly && !recipe.favorite) continue;
    if (state.tags.size && ![...state.tags].every((tag) => (recipe.tags || []).includes(tag))) continue;
    const match = recipeMatch(recipe);
    if (query && !(recipe.searchBlob || computeSearchBlob(recipe)).includes(query)) continue;
    rows.push({ recipe, match });
  }
  if (state.have.length) {
    rows.sort((a, b) => b.match.score - a.match.score || a.match.missing - b.match.missing);
  } else if (state.sort === "az") {
    rows.sort((a, b) => a.recipe.title.localeCompare(b.recipe.title));
  } else if (state.sort === "za") {
    rows.sort((a, b) => b.recipe.title.localeCompare(a.recipe.title));
  }
  return rows;
}

function renderGrid() {
  const rows = filtered();
  const countLabel = rows.length === 1 ? t("recipeCountOne", { n: rows.length }) : t("recipeCountOther", { n: rows.length });
  if (state.have.length) {
    els.status.textContent = t("closestFit", { count: countLabel });
  } else {
    els.status.textContent = countLabel;
  }
  if (!rows.length) {
    els.grid.innerHTML = `<div class="empty">${escapeHtml(t("noMatch"))}</div>`;
    return;
  }
  els.grid.innerHTML = rows.map(cardHtml).join("");
}

function cardHtml({ recipe, match }) {
  const tags = [];
  if (state.have.length) {
    const label = match.fullyCovered
      ? t("bestFit")
      : match.missing
        ? t("fitMissing", { pct: Math.round(match.score * 100), n: match.missing })
        : t("fitPct", { pct: Math.round(match.score * 100) });
    tags.unshift(`<span class="pill match">${escapeHtml(label)}</span>`);
  }
  const favoriteActive = recipe.favorite ? " active" : "";
  return `
    <div class="card" data-id="${recipe.id}">
      <div class="card-actions">
        <button class="card-icon-btn favorite${favoriteActive}" type="button" data-action="toggle-favorite" data-id="${recipe.id}" aria-label="${escapeAttr(t("favorite"))}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="${recipe.favorite ? "currentColor" : "none"}" stroke="currentColor" stroke-width="1.8"><path d="M12 3.6c-2-2.3-5.4-2.6-7.5-.4-2.2 2.2-2.1 5.8.3 8.1L12 18.6l7.2-7.3c2.4-2.3 2.5-5.9.3-8.1-2.1-2.2-5.5-1.9-7.5.4z"/></svg>
        </button>
      </div>
      <button class="card-body" type="button" data-action="open-recipe" data-id="${recipe.id}" style="text-align:left; background:none; border:none; cursor:pointer; padding:1.1rem; font:inherit; color:inherit;">
        <h2>${escapeHtml(recipe.title)}</h2>
        ${tags.length ? `<div class="meta">${tags.join("")}</div>` : ""}
      </button>
    </div>`;
}

// ---------- recipe detail drawer ----------

function openRecipe(id) {
  id = Number(id);
  const recipe = state.recipes.find((item) => item.id === id);
  if (!recipe) return;
  state.openRecipeId = id;
  state.editingId = null;
  location.hash = `#recipe/${id}`;
  els.detail.innerHTML = recipeHtml(recipe);
  els.drawer.hidden = false;
}

// Downscales to at most maxDimension on the longest side and re-encodes as
// JPEG — a recipe card/cookbook page stays perfectly legible to Gemini at
// this size, and it keeps the upload well under Vercel's request body limit.
function resizeImageFile(file, maxDimension = 1600, quality = 0.7) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      URL.revokeObjectURL(url);
      const longest = Math.max(img.width, img.height);
      const scale = longest > maxDimension ? maxDimension / longest : 1;
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      const ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      canvas.toBlob((blob) => {
        if (blob) resolve(blob);
        else reject(new Error(t("couldNotProcessPhoto")));
      }, "image/jpeg", quality);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error(t("couldNotReadPhoto")));
    };
    img.src = url;
  });
}

function showPhotoLoading(show) {
  let overlay = document.getElementById("photo-loading-overlay");
  if (show) {
    if (overlay) return;
    overlay = document.createElement("div");
    overlay.id = "photo-loading-overlay";
    overlay.className = "photo-loading-overlay";
    overlay.innerHTML = `<div class="photo-loading-box"><div class="spinner"></div><span>${escapeHtml(t("readingRecipe"))}</span></div>`;
    document.body.appendChild(overlay);
  } else if (overlay) {
    overlay.remove();
  }
}

async function handlePhotoSelected(event) {
  const file = event.target.files && event.target.files[0];
  if (!file) return;
  showPhotoLoading(true);
  try {
    const blob = await resizeImageFile(file);
    const formData = new FormData();
    formData.append("photo", blob, "photo.jpg");
    const response = await fetch("/api/extract-photo", {
      method: "POST",
      headers: authHeaders(),
      body: formData,
    });
    if (!response.ok) throw await errorForResponse(response);
    const extraction = await response.json();
    openAddRecipe(extraction);
  } catch (err) {
    window.alert(t("couldntReadPhoto", { error: err.message }));
  } finally {
    showPhotoLoading(false);
  }
}

function openAddRecipe(prefill) {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = true;
  els.detail.innerHTML = addRecipeFormHtml(prefill || null);
  els.drawer.hidden = false;
}

function refreshOpenRecipe() {
  if (state.openRecipeId == null) return;
  const recipe = state.recipes.find((item) => item.id === state.openRecipeId);
  if (!recipe) {
    closeDrawer();
    return;
  }
  els.detail.innerHTML = recipeHtml(recipe);
}

function recipeHtml(recipe) {
  if (state.editingId === recipe.id) return editFormHtml(recipe);

  const bits = [
    recipe.course && COURSES.includes(recipe.course) ? t(recipe.course) : recipe.course,
    recipe.servings ? t("servings", { n: recipe.servings }) : null,
    recipe.time,
  ].filter(Boolean);
  const tags = (recipe.tags || [])
    .map((tag) => `<button class="pill pill-btn-plain" type="button" data-action="filter-tag" data-tag="${escapeAttr(tag)}">${escapeHtml(tTag(tag))}</button>`)
    .join("");
  const ingredients = (recipe.ingredients || [])
    .map((item) => {
      const { quantity, text } = splitIngredientQuantity(item);
      if (quantity) {
        return `<li><span class="qty">${escapeHtml(quantity)}</span><span>${escapeHtml(text)}</span></li>`;
      }
      return `<li class="ingredient-plain"><span>${escapeHtml(text)}</span></li>`;
    })
    .join("");
  const steps = (recipe.steps || [])
    .map((item, index) => `<li><span class="step-num">${index + 1}</span><span>${escapeHtml(item)}</span></li>`)
    .join("");
  const originalPostItem = recipe.source
    ? `<a href="${escapeAttr(recipe.source)}" target="_blank" rel="noopener">${escapeHtml(t("originalPost"))}</a>`
    : "";
  const notesSection = recipe.notes
    ? `<h3>${escapeHtml(t("notes"))}</h3><p class="notes-box">${escapeHtml(recipe.notes)}</p>`
    : "";

  const missing = state.have.length ? missingIngredients(recipe) : [];
  const pantryNote = !state.have.length
    ? ""
    : missing.length
      ? `<div class="pantry-match missing">
          <span>${escapeHtml(missing.length === 1 ? t("missingFromHaveOne", { n: missing.length, list: missing.join(", ") }) : t("missingFromHaveOther", { n: missing.length, list: missing.join(", ") }))}</span>
        </div>`
      : `<div class="pantry-match covered">${escapeHtml(t("haveEverything"))}</div>`;

  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("close"))}
      </button>
      <div class="action-group">
        <button class="pill-btn favorite${recipe.favorite ? " active" : ""}" type="button" data-action="toggle-favorite" data-id="${recipe.id}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3.6c-2-2.3-5.4-2.6-7.5-.4-2.2 2.2-2.1 5.8.3 8.1L12 18.6l7.2-7.3c2.4-2.3 2.5-5.9.3-8.1-2.1-2.2-5.5-1.9-7.5.4z"/></svg>
          ${escapeHtml(t("favorite"))}
        </button>
        <div class="menu-anchor">
          <button class="pill-btn menu-btn" type="button" data-action="toggle-recipe-menu" aria-haspopup="true" aria-expanded="false">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/></svg>
          </button>
          <div class="recipe-menu" hidden>
            ${originalPostItem}
            <button type="button" data-action="start-edit" data-id="${recipe.id}">${escapeHtml(t("edit"))}</button>
            <button type="button" class="danger" data-action="delete-recipe" data-id="${recipe.id}">${escapeHtml(t("deleteRecipe"))}</button>
          </div>
        </div>
      </div>
    </div>
    <div class="hero-plain">
      <p class="eyebrow">${escapeHtml(bits.join(" · "))}</p>
      <h2 id="recipe-title">${escapeHtml(recipe.title)}</h2>
    </div>
    ${pantryNote}
    <div class="recipe recipe-body">
      <h3>${escapeHtml(t("ingredients"))}</h3>
      <ul class="ingredients">${ingredients || `<li>${escapeHtml(t("noneListed"))}</li>`}</ul>
      <h3>${escapeHtml(t("steps"))}</h3>
      <ol class="steps">${steps || `<li>${escapeHtml(t("noneListed"))}</li>`}</ol>
      ${notesSection}
      ${tags ? `<div class="meta">${tags}</div>` : ""}
    </div>`;
}

function editFormHtml(recipe) {
  return `
    <div class="drawer-actions editing">
      <button class="icon-btn" type="button" data-action="cancel-edit">${escapeHtml(t("cancel"))}</button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(t("editRecipe"))}</h2>
      <label class="field">
        <span>${escapeHtml(t("title"))}</span>
        <input id="edit-title" value="${escapeAttr(recipe.title)}">
      </label>
      <div class="field">
        <span>${escapeHtml(t("course"))}</span>
        <input type="hidden" id="edit-course" value="${escapeAttr(recipe.course && COURSES.includes(recipe.course) ? recipe.course : "Main course")}">
        <div id="edit-course-chips" class="chips">${courseChipsHtml(recipe.course && COURSES.includes(recipe.course) ? recipe.course : "Main course", "pick-edit-course")}</div>
      </div>
      <label class="field">
        <span>${escapeHtml(t("ingredientsOnePerLine"))}</span>
        <textarea id="edit-ingredients" rows="8">${escapeHtml((recipe.ingredients || []).join("\n"))}</textarea>
      </label>
      <label class="field">
        <span>${escapeHtml(t("stepsOnePerLine"))}</span>
        <textarea id="edit-steps" rows="10">${escapeHtml((recipe.steps || []).join("\n"))}</textarea>
      </label>
      <label class="field">
        <span>${escapeHtml(t("notes"))}</span>
        <textarea id="edit-notes" rows="3">${escapeHtml(recipe.notes || "")}</textarea>
      </label>
      <div class="field">
        <span>${escapeHtml(t("tags"))}</span>
        <input type="hidden" id="edit-tags" value="${escapeAttr((recipe.tags || []).join(", "))}">
        <div id="edit-tag-chips" class="chips">${existingTagChips("pick-edit-tag", recipe.tags || [])}</div>
        ${tagDraftRow("edit")}
      </div>
      <p id="edit-error" class="edit-error" hidden></p>
      <button class="pill-btn primary" type="button" data-action="save-edit" data-id="${recipe.id}">${escapeHtml(t("save"))}</button>
    </div>`;
}

// Mirrors app/models.py's _clean_user_tags (the canonical spec — see its
// docstring) and ios/RecipeBox/Models.swift's normalizeRecipeTag. Keep the
// three in sync: strip commas, collapse whitespace, clip to
// MAX_RECIPE_TAG_LENGTH, case-fold against RECIPE_TAGS else lowercase.
function normalizeUserTag(raw) {
  const text = String(raw || "").replaceAll(",", " ").replace(/\s+/g, " ").trim();
  if (!text) return "";
  const clipped = text.slice(0, MAX_RECIPE_TAG_LENGTH).trim();
  if (!clipped) return "";
  const known = RECIPE_TAGS.find((tag) => tag.toLowerCase() === clipped.toLowerCase());
  return known || clipped.toLowerCase();
}

function offeredFormTags(selectedTags) {
  const seen = new Set();
  const ordered = [];
  for (const tag of [...RECIPE_TAGS, ...state.knownTags, ...state.recipes.flatMap((recipe) => recipe.tags || []), ...selectedTags]) {
    const key = String(tag || "").toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    ordered.push(tag);
  }
  return ordered;
}

function existingTagChips(action, selectedTags) {
  return offeredFormTags(selectedTags).map((tag) => {
    const active = selectedTags.some((selected) => selected.toLowerCase() === tag.toLowerCase());
    return chipButtonHtml({ className: "pill pill-btn-plain", action, dataAttr: "tag", value: tag, active, label: tTag(tag) });
  }).join("");
}

function tagDraftRow(which) {
  return `<div class="tag-add-row">
        <input id="${which}-tag-draft" maxlength="${MAX_RECIPE_TAG_LENGTH}" placeholder="${escapeAttr(t("newTag"))}" autocomplete="off">
        <button class="pill-btn" type="button" data-action="add-custom-tag" data-which="${which}">${escapeHtml(t("addTag"))}</button>
      </div>`;
}

function selectedTagsFromInput(inputEl) {
  return (inputEl.value || "").split(",").map((item) => item.trim()).filter(Boolean);
}

function refreshTagChips(which) {
  const action = which === "edit" ? "pick-edit-tag" : "pick-add-tag";
  const input = document.getElementById(`${which}-tags`);
  const chipsEl = document.getElementById(`${which}-tag-chips`);
  if (!input || !chipsEl) return;
  chipsEl.innerHTML = existingTagChips(action, selectedTagsFromInput(input));
}

function toggleTagInInput(inputEl, tag) {
  const current = selectedTagsFromInput(inputEl);
  const index = current.findIndex((item) => item.toLowerCase() === tag.toLowerCase());
  if (index >= 0) current.splice(index, 1);
  else if (current.length < MAX_RECIPE_TAGS) current.push(normalizeUserTag(tag) || tag);
  inputEl.value = current.join(", ");
}

function addCustomTag(which) {
  const input = document.getElementById(`${which}-tags`);
  const draftEl = document.getElementById(`${which}-tag-draft`);
  if (!input || !draftEl) return;
  const tag = normalizeUserTag(draftEl.value);
  if (!tag) return;
  const current = selectedTagsFromInput(input);
  if (current.some((item) => item.toLowerCase() === tag) || current.length >= MAX_RECIPE_TAGS) return;
  current.push(tag);
  input.value = current.join(", ");
  draftEl.value = "";
  if (!state.knownTags.some((item) => item.toLowerCase() === tag.toLowerCase())) {
    state.knownTags.push(tag);
  }
  refreshTagChips(which);
}

function addRecipeFormHtml(prefill) {
  const courseValue = courseFromMeal(prefill?.meal);
  const ingredientsValue = prefill ? prefill.ingredients.join("\n") : "";
  const stepsValue = prefill ? prefill.steps.join("\n") : "";
  const prefillTags = prefill ? prefill.tags : [];

  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("cancel"))}
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(t("addRecipeTitle"))}</h2>
      ${prefill ? `<p style="margin:-0.8rem 0 1.2rem; color:var(--ink-soft); font-size:0.85rem;">${escapeHtml(t("photoPrefillHint"))}</p>` : ""}
      <label class="field">
        <span>${escapeHtml(t("title"))}</span>
        <input id="add-title" placeholder="${escapeAttr(t("title"))}" value="${escapeAttr(prefill?.title || "")}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("ingredientsOnePerLine"))}</span>
        <textarea id="add-ingredients" rows="8">${escapeHtml(ingredientsValue)}</textarea>
      </label>
      <label class="field">
        <span>${escapeHtml(t("stepsOnePerLine"))}</span>
        <textarea id="add-steps" rows="10">${escapeHtml(stepsValue)}</textarea>
      </label>
      <div class="field">
        <span>${escapeHtml(t("course"))}</span>
        <input type="hidden" id="add-course" value="${escapeAttr(courseValue)}">
        <div id="add-course-chips" class="chips">${courseChipsHtml(courseValue, "pick-add-course")}</div>
      </div>
      <div class="field">
        <span>${escapeHtml(t("tags"))}</span>
        <input type="hidden" id="add-tags" value="${escapeAttr(prefillTags.join(", "))}">
        <div id="add-tag-chips" class="chips">${existingTagChips("pick-add-tag", prefillTags)}</div>
        ${tagDraftRow("add")}
      </div>
      <label class="field">
        <span>${escapeHtml(t("notes"))}</span>
        <textarea id="add-notes" rows="3"></textarea>
      </label>
      <p id="add-error" class="edit-error" hidden></p>
      <button class="pill-btn primary" type="button" data-action="save-add-recipe">${escapeHtml(t("save"))}</button>
    </div>`;
}

async function saveAddRecipe() {
  const titleInput = document.getElementById("add-title");
  const ingredientsInput = document.getElementById("add-ingredients");
  const stepsInput = document.getElementById("add-steps");
  const courseInput = document.getElementById("add-course");
  const tagsInput = document.getElementById("add-tags");
  const notesInput = document.getElementById("add-notes");
  const errorEl = document.getElementById("add-error");
  const saveBtn = document.querySelector('[data-action="save-add-recipe"]');

  const title = titleInput.value.trim();
  if (!title) {
    errorEl.textContent = t("titleEmpty");
    errorEl.hidden = false;
    return;
  }

  const draft = {
    title,
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
    course: courseInput.value || "Main course",
    tags: tagsInput.value.split(",").map((tag) => tag.trim()).filter(Boolean),
    notes: notesInput.value.trim(),
  };

  saveBtn.disabled = true;
  saveBtn.textContent = t("saving");
  try {
    const created = await createRecipeRequest(draft);
    created.searchBlob = computeSearchBlob(created);
    state.recipes.unshift(created);
    state.addingRecipe = false;
    closeDrawer();
    renderFilters();
    renderGrid();
  } catch (err) {
    errorEl.textContent = t("couldntSave", { error: err.message });
    errorEl.hidden = false;
    saveBtn.disabled = false;
    saveBtn.textContent = t("save");
  }
}

async function toggleFavorite(id) {
  id = Number(id);
  const recipe = state.recipes.find((item) => item.id === id);
  if (!recipe) return;
  const optimistic = !recipe.favorite;
  recipe.favorite = optimistic;
  renderGrid();
  refreshOpenRecipe();
  try {
    const updated = await patchRecipe(id, { favorite: optimistic });
    Object.assign(recipe, updated);
  } catch (err) {
    recipe.favorite = !optimistic;
    window.alert(t("couldntSave", { error: err.message }));
  }
  renderGrid();
  refreshOpenRecipe();
}

function startEdit(id) {
  state.editingId = Number(id);
  refreshOpenRecipe();
}

function cancelEdit() {
  state.editingId = null;
  refreshOpenRecipe();
}

async function saveEdit(id) {
  id = Number(id);
  const titleInput = document.getElementById("edit-title");
  const ingredientsInput = document.getElementById("edit-ingredients");
  const stepsInput = document.getElementById("edit-steps");
  const notesInput = document.getElementById("edit-notes");
  const tagsInput = document.getElementById("edit-tags");
  const courseInput = document.getElementById("edit-course");
  const errorEl = document.getElementById("edit-error");
  const saveBtn = document.querySelector('[data-action="save-edit"]');

  const title = titleInput.value.trim();
  if (!title) {
    errorEl.textContent = t("titleEmpty");
    errorEl.hidden = false;
    return;
  }

  const patch = {
    title,
    notes: notesInput.value.trim(),
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
    tags: tagsInput.value.split(",").map((tag) => tag.trim()).filter(Boolean),
    course: courseInput?.value || "Main course",
  };

  saveBtn.disabled = true;
  saveBtn.textContent = t("saving");
  try {
    const updated = await patchRecipe(id, patch);
    const recipe = state.recipes.find((item) => item.id === id);
    if (recipe) {
      Object.assign(recipe, updated);
      recipe.searchBlob = computeSearchBlob(recipe);
    }
    state.editingId = null;
    renderGrid();
    refreshOpenRecipe();
  } catch (err) {
    errorEl.textContent = t("couldntSave", { error: err.message });
    errorEl.hidden = false;
    saveBtn.disabled = false;
    saveBtn.textContent = t("save");
  }
}

function linesFrom(text) {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

async function deleteRecipe(id) {
  id = Number(id);
  const recipe = state.recipes.find((item) => item.id === id);
  if (!recipe) return;
  if (!window.confirm(t("deleteConfirm"))) return;
  try {
    await deleteRecipeRequest(id);
    state.recipes = state.recipes.filter((item) => item.id !== id);
    closeDrawer();
    renderFilters();
    renderGrid();
  } catch (err) {
    window.alert(t("couldntDelete", { error: err.message }));
  }
}

function closeDrawer() {
  els.drawer.hidden = true;
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  if (location.hash.startsWith("#recipe/")) {
    history.replaceState(null, "", location.pathname);
  }
}

function maybeOpenFromHash() {
  const match = location.hash.match(/^#recipe\/(\d+)/);
  if (match) openRecipe(match[1]);
}

function unique(values) {
  return [...new Set(values.filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

// Debounced like iOS's DebouncedTextField — filtering the full list (plus
// pantry matching against "what I have") on every single keystroke is
// wasted work while the user is still typing. Drives both the recipe grid
// and the "mark as something you have" suggestion row below the box — one
// input, two jobs, rather than a separate search elsewhere for the second
// one. (No Enter-to-add here, unlike the old dedicated pantry search: this
// box's main job is finding a recipe by name, and a bare Enter shouldn't
// silently file whatever you typed as a pantry item — tapping the "+ Add"
// suggestion is an explicit, deliberate action instead.)
let searchDebounceTimer = null;
els.search.addEventListener("input", () => {
  const value = els.search.value;
  clearTimeout(searchDebounceTimer);
  searchDebounceTimer = setTimeout(() => {
    state.query = value;
    renderGrid();
    renderSearchSuggest();
  }, 160);
});

els.favoritesToggle.addEventListener("click", () => {
  state.favoritesOnly = !state.favoritesOnly;
  renderFilters();
  renderGrid();
});

els.filtersBtn.addEventListener("click", () => {
  if (els.filtersPanel.hidden) openFilters();
  else closeFilters();
});

els.filtersReset.addEventListener("click", () => {
  state.tags = new Set();
  state.favoritesOnly = false;
  state.sort = "recent";
  renderFilters();
  renderGrid();
});

document.getElementById("sort-options").addEventListener("click", (event) => {
  const btn = event.target.closest("[data-sort]");
  if (!btn) return;
  state.sort = btn.dataset.sort;
  document
    .querySelectorAll("#sort-options .chip")
    .forEach((chip) => chip.classList.toggle("active", chip.dataset.sort === state.sort));
  renderGrid();
});

document.addEventListener("click", (event) => {
  if (els.filtersPanel.hidden) return;
  if (els.filtersPanel.contains(event.target) || els.filtersBtn.contains(event.target)) return;
  closeFilters();
});

document.addEventListener("click", (event) => {
  const menu = document.querySelector(".recipe-menu");
  if (!menu || menu.hidden) return;
  if (menu.contains(event.target) || event.target.closest('[data-action="toggle-recipe-menu"]')) return;
  closeRecipeMenu();
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !els.filtersPanel.hidden) closeFilters();
});

els.settingsBtn.addEventListener("click", openSettings);
els.addRecipeBtn.addEventListener("click", () => {
  els.addRecipeMenu.hidden = !els.addRecipeMenu.hidden;
  els.addRecipeBtn.setAttribute("aria-expanded", String(!els.addRecipeMenu.hidden));
});

document.addEventListener("click", (event) => {
  if (els.addRecipeMenu.hidden) return;
  if (els.addRecipeMenu.contains(event.target) || els.addRecipeBtn.contains(event.target)) return;
  els.addRecipeMenu.hidden = true;
  els.addRecipeBtn.setAttribute("aria-expanded", "false");
});

els.photoInput.addEventListener("change", handlePhotoSelected);

document.addEventListener("click", (event) => {
  const pantry = event.target.closest("[data-pantry]");
  if (pantry) {
    togglePantry(pantry.dataset.pantry);
    return;
  }

  const actionEl = event.target.closest("[data-action]");
  if (!actionEl) {
    const card = event.target.closest(".card");
    if (card) openRecipe(card.dataset.id);
    return;
  }

  const { action, id } = actionEl.dataset;
  switch (action) {
    case "open-recipe":
      openRecipe(id);
      break;
    case "toggle-favorite":
      event.stopPropagation();
      toggleFavorite(id);
      break;
    case "toggle-recipe-menu":
      event.stopPropagation();
      toggleRecipeMenu();
      break;
    case "close-drawer":
      closeDrawer();
      break;
    case "save-settings":
      saveSettings();
      break;
    case "toggle-developer":
      state.devSettingsOpen = !state.devSettingsOpen;
      renderSettings();
      break;
    case "filter-tag":
      closeDrawer();
      state.tags = new Set([actionEl.dataset.tag]);
      renderFilters();
      renderGrid();
      break;
    case "toggle-tag-filter": {
      const tag = actionEl.dataset.tag;
      if (state.tags.has(tag)) state.tags.delete(tag);
      else state.tags.add(tag);
      renderFilters();
      renderGrid();
      break;
    }
    case "add-pantry-item":
      addHaveItem(actionEl.dataset.item);
      break;
    case "start-edit":
      startEdit(id);
      break;
    case "cancel-edit":
      cancelEdit();
      break;
    case "save-edit":
      saveEdit(id);
      break;
    case "delete-recipe":
      deleteRecipe(id);
      break;
    case "save-add-recipe":
      saveAddRecipe();
      break;
    case "pick-add-course":
    case "pick-edit-course":
      setCourseSelection(action === "pick-edit-course" ? "edit" : "add", actionEl.dataset.course);
      break;
    case "pick-add-tag":
    case "pick-edit-tag": {
      const which = action === "pick-edit-tag" ? "edit" : "add";
      const input = document.getElementById(`${which}-tags`);
      if (!input) break;
      toggleTagInInput(input, actionEl.dataset.tag);
      refreshTagChips(which);
      break;
    }
    case "add-custom-tag":
      addCustomTag(actionEl.dataset.which === "edit" ? "edit" : "add");
      break;
    case "open-add-recipe":
      els.addRecipeMenu.hidden = true;
      openAddRecipe();
      break;
    case "open-add-photo":
      els.addRecipeMenu.hidden = true;
      els.photoInput.value = "";
      els.photoInput.click();
      break;
    default:
      break;
  }
});

els.drawer.addEventListener("click", (event) => {
  if (event.target === els.drawer) closeDrawer();
});
window.addEventListener("hashchange", maybeOpenFromHash);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeDrawer();
  if (event.key === "Enter" && event.target && (event.target.id === "add-tag-draft" || event.target.id === "edit-tag-draft")) {
    event.preventDefault();
    addCustomTag(event.target.id.startsWith("edit") ? "edit" : "add");
  }
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    load({ silent: true }).catch(() => {});
  }
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted) load({ silent: true }).catch(() => {});
});
window.addEventListener("online", () => {
  load({ silent: true }).catch(() => {});
});

applyStaticI18n();
loadCachedRecipes();
load().catch(() => {
  if (!state.recipes.length) {
    els.status.textContent = t("couldNotLoad");
  } else {
    setOfflineBanner(true);
  }
});
