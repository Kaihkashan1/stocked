const MEAL_LABELS = {
  breakfast: "Breakfast",
  lunch: "Lunch",
  dinner: "Dinner",
  snack: "Snack",
  dessert: "Dessert",
  drink: "Drink",
  other: "Other",
};

const STAPLES = new Set(["salt", "water", "oil", "pepper", "black pepper", "sugar"]);

// The whole tag vocabulary, on purpose — kept short and closed rather than
// letting every recipe accumulate its own free-form set. Filtering and the
// Add/Edit forms only ever offer these; there's no way to type a new one in.
const RECIPE_TAGS = ["mom's recipes", "veg", "non-veg", "dessert", "high protein", "airfryer"];

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

const state = {
  recipes: [],
  pantryGroups: [],
  tags: new Set(),
  query: "",
  have: loadHave(),
  favoritesOnly: false,
  sort: "recent",
  openRecipeId: null,
  editingId: null,
  addingRecipe: false,
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
};

async function load() {
  els.status.textContent = "Loading recipes…";
  const response = await fetch("/api/recipes");
  if (!response.ok) {
    els.status.textContent = "Could not load recipes.";
    return;
  }
  const data = await response.json();
  state.recipes = (data.recipes || []).map((recipe) => {
    recipe.searchBlob = computeSearchBlob(recipe);
    return recipe;
  });
  state.pantryGroups = Array.isArray(data.pantry) ? data.pantry : [];
  renderFilters();
  renderGrid();
  maybeOpenFromHash();
  await fetchHave();
  renderFilters();
  renderGrid();
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
  const current = localStorage.getItem(SECRET_KEY) || "";
  const value = window.prompt(
    "Edit key — same value as RECIPE_BOX_SECRET on the server. Needed to favorite, edit, or delete from here. Leave blank against a dev server with no secret set.",
    current
  );
  if (value === null) return;
  localStorage.setItem(SECRET_KEY, value.trim());
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
    window.alert(`Couldn't save your pantry: ${err.message}`);
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
    : `<span class="status">Nothing marked yet</span>`;
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
    ? `<button class="chip active" type="button" data-action="add-pantry-item" data-item="${escapeAttr(trimmed)}">+ Add "${escapeHtml(trimmed)}"</button>`
    : "";
  els.searchSuggest.innerHTML = `<span class="search-suggest-label">Mark as something you have:</span>${matchChips}${addChip}`;
  els.searchSuggest.hidden = false;
}

// ---------- filters / recipe grid (existing browse behavior) ----------

function renderFilters() {
  renderHaveChips();

  // The fixed six are always offered, even before any recipe carries one,
  // plus whatever else recipes actually carry — tag entry is free text, so
  // that "whatever else" can grow. Multi-select (AND): a recipe must carry
  // every selected tag.
  const tags = unique([...RECIPE_TAGS, ...state.recipes.flatMap((recipe) => recipe.tags || [])]);
  els.tagFilters.innerHTML = tags
    .map((tag) => {
      const active = state.tags.has(tag);
      return `<button class="chip${active ? " active" : ""}" type="button" data-action="toggle-tag-filter" data-tag="${escapeAttr(tag)}">${escapeHtml(tag)}${active ? " ×" : ""}</button>`;
    })
    .join("");

  els.favoritesToggle.classList.toggle("active", state.favoritesOnly);

  document
    .querySelectorAll("#sort-options .chip")
    .forEach((chip) => chip.classList.toggle("active", chip.dataset.sort === state.sort));

  const activeCount = [state.tags.size > 0, state.favoritesOnly, state.have.length > 0].filter(Boolean).length;
  els.filtersBtn.classList.toggle("active", activeCount > 0);
  els.filtersBtn.textContent = "";
  els.filtersBtn.append(filtersIcon(), document.createTextNode(activeCount > 0 ? `Filters (${activeCount})` : "Filters"));
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
      return `<div class="pantry-group"><h3 class="pantry-heading">${escapeHtml(group.category)}</h3><div class="chips">${chips}</div></div>`;
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
  return [recipe.title, ...(recipe.tags || []), ...(recipe.ingredients || [])].join(" ").toLowerCase();
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
  if (state.have.length) {
    els.status.textContent = `${rows.length} recipe${rows.length === 1 ? "" : "s"} · closest fit to your pantry first`;
  } else {
    els.status.textContent = `${rows.length} recipe${rows.length === 1 ? "" : "s"}`;
  }
  if (!rows.length) {
    els.grid.innerHTML = `<div class="empty">No recipes match those filters yet.</div>`;
    return;
  }
  els.grid.innerHTML = rows.map(cardHtml).join("");
}

function cardHtml({ recipe, match }) {
  const tags = [];
  if (state.have.length) {
    const label = match.fullyCovered
      ? "Best fit"
      : match.missing
        ? `${Math.round(match.score * 100)}% fit · ${match.missing} missing`
        : `${Math.round(match.score * 100)}% fit`;
    tags.unshift(`<span class="pill match">${escapeHtml(label)}</span>`);
  }
  const favoriteActive = recipe.favorite ? " active" : "";
  return `
    <div class="card" data-id="${recipe.id}">
      <div class="card-actions">
        <button class="card-icon-btn favorite${favoriteActive}" type="button" data-action="toggle-favorite" data-id="${recipe.id}" aria-label="Favorite">
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
        else reject(new Error("Could not process that photo."));
      }, "image/jpeg", quality);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Could not read that photo."));
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
    overlay.innerHTML = `<div class="photo-loading-box"><div class="spinner"></div><span>Reading the recipe…</span></div>`;
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
    window.alert(`Couldn't read that photo: ${err.message}`);
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

  const bits = [recipe.servings ? `${recipe.servings} servings` : null, recipe.time].filter(Boolean);
  const tags = (recipe.tags || [])
    .map((tag) => `<button class="pill pill-btn-plain" type="button" data-action="filter-tag" data-tag="${escapeAttr(tag)}">${escapeHtml(tag)}</button>`)
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
    ? `<a href="${escapeAttr(recipe.source)}" target="_blank" rel="noopener">Original post</a>`
    : "";
  const notesSection = recipe.notes
    ? `<h3>Notes</h3><p class="notes-box">${escapeHtml(recipe.notes)}</p>`
    : "";

  const missing = state.have.length ? missingIngredients(recipe) : [];
  const pantryNote = !state.have.length
    ? ""
    : missing.length
      ? `<div class="pantry-match missing">
          <span>Missing ${missing.length} ingredient${missing.length === 1 ? "" : "s"} from your pantry: ${escapeHtml(missing.join(", "))}</span>
        </div>`
      : `<div class="pantry-match covered">You have everything for this.</div>`;

  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        Close
      </button>
      <div class="action-group">
        <button class="pill-btn favorite${recipe.favorite ? " active" : ""}" type="button" data-action="toggle-favorite" data-id="${recipe.id}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3.6c-2-2.3-5.4-2.6-7.5-.4-2.2 2.2-2.1 5.8.3 8.1L12 18.6l7.2-7.3c2.4-2.3 2.5-5.9.3-8.1-2.1-2.2-5.5-1.9-7.5.4z"/></svg>
          Favorite
        </button>
        <div class="menu-anchor">
          <button class="pill-btn menu-btn" type="button" data-action="toggle-recipe-menu" aria-haspopup="true" aria-expanded="false">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/></svg>
          </button>
          <div class="recipe-menu" hidden>
            ${originalPostItem}
            <button type="button" data-action="start-edit" data-id="${recipe.id}">Edit</button>
            <button type="button" class="danger" data-action="delete-recipe" data-id="${recipe.id}">Delete</button>
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
      <h3>Ingredients</h3>
      <ul class="ingredients">${ingredients || "<li>None listed</li>"}</ul>
      <h3>Steps</h3>
      <ol class="steps">${steps || "<li>None listed</li>"}</ol>
      ${notesSection}
      ${tags ? `<div class="meta">${tags}</div>` : ""}
    </div>`;
}

function editFormHtml(recipe) {
  return `
    <div class="drawer-actions editing">
      <button class="icon-btn" type="button" data-action="cancel-edit">Cancel</button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">Edit recipe</h2>
      <label class="field">
        <span>Title</span>
        <input id="edit-title" value="${escapeAttr(recipe.title)}">
      </label>
      <label class="field">
        <span>Servings</span>
        <input id="edit-servings" value="${escapeAttr(recipe.servings || "")}">
      </label>
      <label class="field">
        <span>Ingredients — one per line</span>
        <textarea id="edit-ingredients" rows="8">${escapeHtml((recipe.ingredients || []).join("\n"))}</textarea>
      </label>
      <label class="field">
        <span>Steps — one per line</span>
        <textarea id="edit-steps" rows="10">${escapeHtml((recipe.steps || []).join("\n"))}</textarea>
      </label>
      <label class="field">
        <span>Notes</span>
        <textarea id="edit-notes" rows="3">${escapeHtml(recipe.notes || "")}</textarea>
      </label>
      <div class="field">
        <span>Tags</span>
        <input type="hidden" id="edit-tags" value="${escapeAttr((recipe.tags || []).join(", "))}">
        <div id="edit-tag-chips" class="chips">${existingTagChips("pick-edit-tag", recipe.tags || [])}</div>
      </div>
      <p id="edit-error" class="edit-error" hidden></p>
      <button class="pill-btn primary" type="button" data-action="save-edit" data-id="${recipe.id}">Save</button>
    </div>`;
}

// The fixed six as quick-pick chips, when adding or editing a recipe — tap
// one to toggle it in the tags field. The field itself is still free text,
// so anything else can be typed in too.
function existingTagChips(action, selectedTags) {
  return RECIPE_TAGS.map((tag) => {
    const active = selectedTags.some((selected) => selected.toLowerCase() === tag.toLowerCase());
    return `<button class="pill pill-btn-plain${active ? " active" : ""}" type="button" data-action="${action}" data-tag="${escapeAttr(tag)}">${escapeHtml(tag)}</button>`;
  }).join("");
}

function toggleTagInInput(inputEl, tag) {
  const current = inputEl.value.split(",").map((item) => item.trim()).filter(Boolean);
  const index = current.findIndex((item) => item.toLowerCase() === tag.toLowerCase());
  if (index >= 0) current.splice(index, 1);
  else current.push(tag);
  inputEl.value = current.join(", ");
}

function addRecipeFormHtml(prefill) {
  const mealValue = prefill?.meal || "other";
  const mealOptions = Object.entries(MEAL_LABELS)
    .map(([value, label]) => `<option value="${escapeAttr(value)}"${value === mealValue ? " selected" : ""}>${escapeHtml(label)}</option>`)
    .join("");
  const ingredientsValue = prefill ? prefill.ingredients.join("\n") : "";
  const stepsValue = prefill ? prefill.steps.join("\n") : "";
  const prefillTags = prefill ? prefill.tags : [];

  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        Cancel
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">Add recipe</h2>
      ${prefill ? `<p style="margin:-0.8rem 0 1.2rem; color:var(--ink-soft); font-size:0.85rem;">Read from your photo — check it over before saving.</p>` : ""}
      <label class="field">
        <span>Title</span>
        <input id="add-title" placeholder="Title" value="${escapeAttr(prefill?.title || "")}">
      </label>
      <label class="field">
        <span>Servings</span>
        <input id="add-servings" placeholder="e.g. 4" value="${escapeAttr(prefill?.servings || "")}">
      </label>
      <label class="field">
        <span>Ingredients — one per line</span>
        <textarea id="add-ingredients" rows="8">${escapeHtml(ingredientsValue)}</textarea>
      </label>
      <label class="field">
        <span>Steps — one per line</span>
        <textarea id="add-steps" rows="10">${escapeHtml(stepsValue)}</textarea>
      </label>
      <label class="field">
        <span>Meal</span>
        <select id="add-meal">${mealOptions}</select>
      </label>
      <input type="hidden" id="add-cuisine" value="${escapeAttr(prefill?.cuisine || "")}">
      <label class="field">
        <span>Time</span>
        <input id="add-time" placeholder="e.g. 20 min" value="${escapeAttr(prefill?.time || "")}">
      </label>
      <div class="field">
        <span>Tags</span>
        <input type="hidden" id="add-tags" value="${escapeAttr(prefillTags.join(", "))}">
        <div id="add-tag-chips" class="chips">${existingTagChips("pick-add-tag", prefillTags)}</div>
      </div>
      <label class="field">
        <span>Notes</span>
        <textarea id="add-notes" rows="3"></textarea>
      </label>
      <p id="add-error" class="edit-error" hidden></p>
      <button class="pill-btn primary" type="button" data-action="save-add-recipe">Save</button>
    </div>`;
}

async function saveAddRecipe() {
  const titleInput = document.getElementById("add-title");
  const servingsInput = document.getElementById("add-servings");
  const ingredientsInput = document.getElementById("add-ingredients");
  const stepsInput = document.getElementById("add-steps");
  const mealInput = document.getElementById("add-meal");
  const cuisineInput = document.getElementById("add-cuisine");
  const timeInput = document.getElementById("add-time");
  const tagsInput = document.getElementById("add-tags");
  const notesInput = document.getElementById("add-notes");
  const errorEl = document.getElementById("add-error");
  const saveBtn = document.querySelector('[data-action="save-add-recipe"]');

  const title = titleInput.value.trim();
  if (!title) {
    errorEl.textContent = "Title can't be empty.";
    errorEl.hidden = false;
    return;
  }

  const draft = {
    title,
    servings: servingsInput.value.trim() || null,
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
    meal: mealInput.value,
    cuisine: cuisineInput.value.trim() || "Uncategorized",
    time: timeInput.value.trim() || null,
    tags: tagsInput.value.split(",").map((tag) => tag.trim()).filter(Boolean),
    notes: notesInput.value.trim(),
  };

  saveBtn.disabled = true;
  saveBtn.textContent = "Saving…";
  try {
    const created = await createRecipeRequest(draft);
    created.searchBlob = computeSearchBlob(created);
    state.recipes.unshift(created);
    state.addingRecipe = false;
    closeDrawer();
    renderFilters();
    renderGrid();
  } catch (err) {
    errorEl.textContent = `Couldn't save: ${err.message}`;
    errorEl.hidden = false;
    saveBtn.disabled = false;
    saveBtn.textContent = "Save";
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
    window.alert(`Couldn't save: ${err.message}`);
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
  const servingsInput = document.getElementById("edit-servings");
  const ingredientsInput = document.getElementById("edit-ingredients");
  const stepsInput = document.getElementById("edit-steps");
  const notesInput = document.getElementById("edit-notes");
  const tagsInput = document.getElementById("edit-tags");
  const errorEl = document.getElementById("edit-error");
  const saveBtn = document.querySelector('[data-action="save-edit"]');

  const title = titleInput.value.trim();
  if (!title) {
    errorEl.textContent = "Title can't be empty.";
    errorEl.hidden = false;
    return;
  }

  const patch = {
    title,
    servings: servingsInput.value.trim() || null,
    notes: notesInput.value.trim(),
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
    tags: tagsInput.value.split(",").map((tag) => tag.trim()).filter(Boolean),
  };

  saveBtn.disabled = true;
  saveBtn.textContent = "Saving…";
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
    errorEl.textContent = `Couldn't save: ${err.message}`;
    errorEl.hidden = false;
    saveBtn.disabled = false;
    saveBtn.textContent = "Save";
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
  if (!window.confirm(`Delete "${recipe.title}"? This removes it from your Recipe Box.`)) return;
  try {
    await deleteRecipeRequest(id);
    state.recipes = state.recipes.filter((item) => item.id !== id);
    closeDrawer();
    renderFilters();
    renderGrid();
  } catch (err) {
    window.alert(`Couldn't delete: ${err.message}`);
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
    case "pick-add-tag":
    case "pick-edit-tag": {
      const isEdit = action === "pick-edit-tag";
      const input = document.getElementById(isEdit ? "edit-tags" : "add-tags");
      const chipsEl = document.getElementById(isEdit ? "edit-tag-chips" : "add-tag-chips");
      if (!input) break;
      toggleTagInInput(input, actionEl.dataset.tag);
      if (chipsEl) {
        const selected = input.value.split(",").map((item) => item.trim()).filter(Boolean);
        chipsEl.innerHTML = existingTagChips(action, selected);
      }
      break;
    }
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
});

load().catch(() => {
  els.status.textContent = "Could not load recipes.";
});
