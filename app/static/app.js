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
const PLAN_KEY = "recipeBox.plan";

const state = {
  recipes: [],
  pantryGroups: [],
  tab: "recipes",
  meal: "all",
  cuisine: "all",
  tag: "all",
  query: "",
  have: [],
  pantryQuery: "",
  favoritesOnly: false,
  sort: "recent",
  planIDs: loadPlanIDs(),
  checkedItems: new Set(),
  openRecipeId: null,
  editingId: null,
  addingRecipe: false,
};

const els = {
  search: document.getElementById("search"),
  meals: document.getElementById("meal-filters"),
  cuisines: document.getElementById("cuisine-filters"),
  tagFilters: document.getElementById("tag-filters"),
  favoritesToggle: document.getElementById("favorites-toggle"),
  filtersBtn: document.getElementById("filters-btn"),
  filtersPanel: document.getElementById("filters-panel"),
  filtersReset: document.getElementById("filters-reset"),
  pantrySearch: document.getElementById("pantry-search"),
  pantrySelected: document.getElementById("pantry-selected"),
  pantryOptions: document.getElementById("pantry-options"),
  grid: document.getElementById("grid"),
  status: document.getElementById("status"),
  drawer: document.getElementById("drawer"),
  detail: document.getElementById("recipe-detail"),
  recipesView: document.getElementById("recipes-view"),
  planView: document.getElementById("plan-view"),
  planContent: document.getElementById("plan-content"),
  planBadge: document.getElementById("plan-badge"),
  settingsBtn: document.getElementById("settings-btn"),
  addRecipeBtn: document.getElementById("add-recipe-btn"),
  tabs: document.querySelectorAll(".tab"),
};

async function load() {
  els.status.textContent = "Loading recipes…";
  const response = await fetch("/api/recipes");
  if (!response.ok) {
    els.status.textContent = "Could not load recipes.";
    return;
  }
  const data = await response.json();
  state.recipes = data.recipes || [];
  state.pantryGroups = Array.isArray(data.pantry) ? data.pantry : [];
  renderFilters();
  renderPantry();
  renderGrid();
  renderPlanBadge();
  maybeOpenFromHash();
  await fetchPlan();
  renderPlanBadge();
  renderGrid();
  if (state.tab === "plan") renderPlan();
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

// ---------- plan / grocery list ----------

// The plan syncs through GET/PUT /api/plan (same one this app's iOS
// counterpart uses) so it matches between devices. localStorage is kept
// only as an instant-render cache for first paint, before the fetch
// in load() reconciles it against the server.
function loadPlanIDs() {
  try {
    const raw = localStorage.getItem(PLAN_KEY);
    return new Set(raw ? JSON.parse(raw) : []);
  } catch {
    return new Set();
  }
}

function cachePlanIDs() {
  localStorage.setItem(PLAN_KEY, JSON.stringify([...state.planIDs]));
}

async function fetchPlan() {
  try {
    const response = await fetch("/api/plan");
    if (!response.ok) return;
    const data = await response.json();
    state.planIDs = new Set(data.ids || []);
    cachePlanIDs();
  } catch {
    // keep whatever the local cache had
  }
}

async function putPlan(ids) {
  const response = await fetch("/api/plan", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ ids: [...ids] }),
  });
  if (!response.ok) throw await errorForResponse(response);
  return (await response.json()).ids;
}

// Optimistic, like toggleFavorite: flips locally first, pushes the whole
// set, reverts on failure.
async function togglePlan(id) {
  id = Number(id);
  const previous = new Set(state.planIDs);
  if (state.planIDs.has(id)) {
    state.planIDs.delete(id);
  } else {
    state.planIDs.add(id);
  }
  cachePlanIDs();
  renderPlanBadge();
  renderGrid();
  if (state.tab === "plan") renderPlan();

  try {
    const confirmed = await putPlan(state.planIDs);
    state.planIDs = new Set(confirmed);
  } catch (err) {
    state.planIDs = previous;
    window.alert(`Couldn't save the plan: ${err.message}`);
  }
  cachePlanIDs();
  renderPlanBadge();
  renderGrid();
  if (state.tab === "plan") renderPlan();
}

// One request for the whole clear, rather than N toggles racing to write
// the last (possibly stale) state.
async function clearPlan() {
  const previous = new Set(state.planIDs);
  state.planIDs = new Set();
  cachePlanIDs();
  renderPlanBadge();
  renderGrid();
  renderPlan();

  try {
    const confirmed = await putPlan([]);
    state.planIDs = new Set(confirmed);
  } catch (err) {
    state.planIDs = previous;
    window.alert(`Couldn't save the plan: ${err.message}`);
  }
  cachePlanIDs();
  renderPlanBadge();
  renderGrid();
  renderPlan();
}

function renderPlanBadge() {
  const count = state.planIDs.size;
  els.planBadge.hidden = count === 0;
  els.planBadge.textContent = String(count);
}

function canonicalKey(line, pantry) {
  const lower = line.toLowerCase();
  const matches = (pantry || []).filter((item) => lower.includes(item));
  if (!matches.length) return "other";
  return matches.reduce((a, b) => (b.length > a.length ? b : a));
}

function groupedIngredients(planned) {
  const buckets = new Map();
  const seenLines = new Set();
  for (const recipe of planned) {
    for (const line of recipe.ingredients || []) {
      if (seenLines.has(line)) continue;
      seenLines.add(line);
      const key = canonicalKey(line, recipe.pantry);
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(line);
    }
  }
  return [...buckets.entries()]
    .map(([key, lines]) => ({ key, lines: lines.sort() }))
    .sort((a, b) => a.key.localeCompare(b.key));
}

function renderPlan() {
  const planned = state.recipes.filter((r) => state.planIDs.has(r.id));
  if (!planned.length) {
    els.planContent.innerHTML = `<div class="empty">No recipes planned yet. Tap the cart icon on a recipe to add it here.</div>`;
    return;
  }

  const rows = planned
    .map(
      (recipe) => `
        <div class="plan-row">
          <button class="plan-title" type="button" data-action="open-recipe" data-id="${recipe.id}">${escapeHtml(recipe.title)}</button>
          <button class="icon-btn" type="button" data-action="toggle-plan" data-id="${recipe.id}">Remove</button>
        </div>`
    )
    .join("");

  const groups = groupedIngredients(planned)
    .map((group) => {
      const items = group.lines
        .map((line) => {
          const { quantity, text } = splitIngredientQuantity(line);
          const checked = state.checkedItems.has(line);
          return `
            <label class="grocery-item${checked ? " checked" : ""}">
              <input type="checkbox" data-line="${escapeAttr(line)}" ${checked ? "checked" : ""}>
              ${quantity ? `<span class="qty">${escapeHtml(quantity)}</span>` : ""}
              <span>${escapeHtml(text)}</span>
            </label>`;
        })
        .join("");
      return `
        <div>
          <h3 class="pantry-heading">${escapeHtml(capitalize(group.key))}</h3>
          <div class="grocery-list">${items}</div>
        </div>`;
    })
    .join("");

  els.planContent.innerHTML = `
    <section>
      <h2 class="eyebrow">Planned · ${planned.length} recipe${planned.length === 1 ? "" : "s"}</h2>
      <div class="plan-rows">${rows}</div>
    </section>
    <section>
      <div class="grocery-header">
        <h2>Grocery list</h2>
        <button class="link-btn" type="button" data-action="clear-plan">Clear plan</button>
      </div>
      <div class="grocery-groups">${groups}</div>
    </section>`;
}

function capitalize(value) {
  return value ? value.charAt(0).toUpperCase() + value.slice(1) : value;
}

// ---------- tabs ----------

function setTab(tab) {
  state.tab = tab;
  els.recipesView.hidden = tab !== "recipes";
  els.planView.hidden = tab !== "plan";
  els.tabs.forEach((btn) => btn.classList.toggle("active", btn.dataset.tab === tab));
  if (tab === "plan") renderPlan();
}

// ---------- filters / recipe grid (existing browse behavior) ----------

function renderFilters() {
  const meals = ["all", ...Object.keys(MEAL_LABELS)];
  els.meals.innerHTML = meals
    .map((meal) => chip("meal", meal, meal === "all" ? "All meals" : MEAL_LABELS[meal]))
    .join("");

  const cuisines = ["all", ...unique(state.recipes.map((recipe) => recipe.cuisine))];
  els.cuisines.innerHTML = cuisines
    .map((cuisine) => chip("cuisine", cuisine, cuisine === "all" ? "All cuisines" : cuisine))
    .join("");

  // Tags cover cooking method/appliance (air-fryer, one-pot, ...) as well as
  // diet/flavor — anything Gemini tagged the recipe with — so this is the
  // one place a category like "Air Fryer" becomes a real filter without
  // hardcoding a fixed list.
  const tags = ["all", ...unique(state.recipes.flatMap((recipe) => recipe.tags || []))];
  els.tagFilters.innerHTML = tags.map((tag) => chip("tag", tag, tag === "all" ? "All tags" : tag)).join("");

  els.favoritesToggle.classList.toggle("active", state.favoritesOnly);

  document
    .querySelectorAll("#sort-options .chip")
    .forEach((chip) => chip.classList.toggle("active", chip.dataset.sort === state.sort));

  const activeCount = [state.meal !== "all", state.cuisine !== "all", state.tag !== "all", state.favoritesOnly].filter(
    Boolean
  ).length;
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

function renderPantry() {
  const selected = groupPantry(state.have);
  els.pantrySelected.innerHTML = selected.length
    ? pantryGroupsHtml(selected, true)
    : `<span class="status">Pick ingredients you have</span>`;

  const needle = state.pantryQuery.trim().toLowerCase();
  const options = groupPantry(
    pantryCatalog().filter((item) => !state.have.includes(item) && pantryQueryMatch(item, needle))
  );
  els.pantryOptions.innerHTML = options.length
    ? pantryGroupsHtml(options, false)
    : `<span class="status">No matching ingredients</span>`;
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

function chip(kind, value, label) {
  const active = state[kind] === value ? " active" : "";
  return `<button class="chip${active}" type="button" data-kind="${kind}" data-value="${escapeAttr(value)}">${escapeHtml(label)}</button>`;
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

function recipeMatch(recipe) {
  if (!state.have.length) return { ok: true, score: 0, extra: 0 };
  const pantry = recipe.pantry || [];
  const haystack = pantry;
  for (const wanted of state.have) {
    if (!haystack.some((have) => namesMatch(wanted, have))) {
      return { ok: false, score: 0, extra: 0 };
    }
  }
  const core = pantry.filter((item) => !STAPLES.has(item));
  const extra = core.filter((item) => !state.have.some((wanted) => namesMatch(item, wanted)));
  const total = Math.max(core.length, 1);
  return { ok: true, score: state.have.length / total, extra: extra.length };
}

function filtered() {
  const query = state.query.trim().toLowerCase();
  const rows = [];
  for (const recipe of state.recipes) {
    if (state.favoritesOnly && !recipe.favorite) continue;
    if (state.meal !== "all" && recipe.meal !== state.meal) continue;
    if (state.cuisine !== "all" && recipe.cuisine !== state.cuisine) continue;
    if (state.tag !== "all" && !(recipe.tags || []).includes(state.tag)) continue;
    const match = recipeMatch(recipe);
    if (!match.ok) continue;
    if (query) {
      const haystack = [
        recipe.title,
        recipe.cuisine,
        recipe.meal,
        ...(recipe.tags || []),
        ...(recipe.ingredients || []),
      ]
        .join(" ")
        .toLowerCase();
      if (!haystack.includes(query)) continue;
    }
    rows.push({ recipe, match });
  }
  if (state.have.length) {
    rows.sort((a, b) => b.match.score - a.match.score || a.match.extra - b.match.extra);
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
    els.status.textContent = `${rows.length} recipe${rows.length === 1 ? "" : "s"} using ${state.have.join(" + ")} · closest fit first`;
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
  const tags = [`<span class="pill">${escapeHtml(recipe.cuisine)}</span>`];
  if (recipe.meal && recipe.meal !== "other") {
    tags.push(`<span class="pill warm">${escapeHtml(MEAL_LABELS[recipe.meal] || recipe.meal)}</span>`);
  }
  if (state.have.length) {
    const label =
      match.percent === 100 || match.score === 1
        ? "Best fit"
        : match.extra
          ? `${Math.round(match.score * 100)}% fit · ${match.extra} extra`
          : `${Math.round(match.score * 100)}% fit`;
    tags.unshift(`<span class="pill match">${escapeHtml(label)}</span>`);
  }
  const favoriteActive = recipe.favorite ? " active" : "";
  const planActive = state.planIDs.has(recipe.id) ? " active" : "";
  return `
    <div class="card" data-id="${recipe.id}">
      <div class="card-actions">
        <button class="card-icon-btn favorite${favoriteActive}" type="button" data-action="toggle-favorite" data-id="${recipe.id}" aria-label="Favorite">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="${recipe.favorite ? "currentColor" : "none"}" stroke="currentColor" stroke-width="1.8"><path d="M12 3.6c-2-2.3-5.4-2.6-7.5-.4-2.2 2.2-2.1 5.8.3 8.1L12 18.6l7.2-7.3c2.4-2.3 2.5-5.9.3-8.1-2.1-2.2-5.5-1.9-7.5.4z"/></svg>
        </button>
        <button class="card-icon-btn plan${planActive}" type="button" data-action="toggle-plan" data-id="${recipe.id}" aria-label="Add to plan">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M2.5 3h2.4l2.1 11.4a2 2 0 0 0 2 1.6h8.3a2 2 0 0 0 2-1.6L21 7H6"/><circle cx="9" cy="20" r="1.3" fill="currentColor" stroke="none"/><circle cx="18" cy="20" r="1.3" fill="currentColor" stroke="none"/></svg>
        </button>
      </div>
      <button class="card-body" type="button" data-action="open-recipe" data-id="${recipe.id}" style="text-align:left; background:none; border:none; cursor:pointer; padding:1.1rem; font:inherit; color:inherit;">
        <h2>${escapeHtml(recipe.title)}</h2>
        <div class="meta">${tags.join("")}</div>
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

function openAddRecipe() {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = true;
  els.detail.innerHTML = addRecipeFormHtml();
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
    recipe.cuisine,
    MEAL_LABELS[recipe.meal] || recipe.meal,
    recipe.servings ? `${recipe.servings} servings` : null,
    recipe.time,
  ].filter(Boolean);
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
    <div class="recipe recipe-body">
      <div class="meta">${tags}</div>
      <h3>Ingredients</h3>
      <ul class="ingredients">${ingredients || "<li>None listed</li>"}</ul>
      <h3>Steps</h3>
      <ol class="steps">${steps || "<li>None listed</li>"}</ol>
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
      <p id="edit-error" class="edit-error" hidden></p>
      <button class="pill-btn primary" type="button" data-action="save-edit" data-id="${recipe.id}">Save</button>
    </div>`;
}

function addRecipeFormHtml() {
  const cuisines = unique(state.recipes.map((recipe) => recipe.cuisine));
  const mealOptions = Object.entries(MEAL_LABELS)
    .map(([value, label]) => `<option value="${escapeAttr(value)}"${value === "other" ? " selected" : ""}>${escapeHtml(label)}</option>`)
    .join("");
  const cuisineChips = cuisines
    .map((cuisine) => `<button class="pill pill-btn-plain" type="button" data-action="pick-add-cuisine" data-cuisine="${escapeAttr(cuisine)}">${escapeHtml(cuisine)}</button>`)
    .join("");

  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        Cancel
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">Add recipe</h2>
      <label class="field">
        <span>Title</span>
        <input id="add-title" placeholder="Title">
      </label>
      <label class="field">
        <span>Servings</span>
        <input id="add-servings" placeholder="e.g. 4">
      </label>
      <label class="field">
        <span>Ingredients — one per line</span>
        <textarea id="add-ingredients" rows="8"></textarea>
      </label>
      <label class="field">
        <span>Steps — one per line</span>
        <textarea id="add-steps" rows="10"></textarea>
      </label>
      <label class="field">
        <span>Meal</span>
        <select id="add-meal">${mealOptions}</select>
      </label>
      <label class="field">
        <span>Cuisine</span>
        <input id="add-cuisine" placeholder="e.g. Italian">
      </label>
      ${cuisineChips ? `<div class="chips" style="margin:-0.6rem 0 1.1rem;">${cuisineChips}</div>` : ""}
      <label class="field">
        <span>Time</span>
        <input id="add-time" placeholder="e.g. 20 min">
      </label>
      <label class="field">
        <span>Tags — comma separated</span>
        <input id="add-tags" placeholder="quick, vegetarian">
      </label>
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
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
  };

  saveBtn.disabled = true;
  saveBtn.textContent = "Saving…";
  try {
    const updated = await patchRecipe(id, patch);
    const recipe = state.recipes.find((item) => item.id === id);
    if (recipe) Object.assign(recipe, updated);
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
    if (state.planIDs.delete(id)) {
      cachePlanIDs();
      putPlan(state.planIDs).then((ids) => { state.planIDs = new Set(ids); }).catch(() => {});
    }
    closeDrawer();
    renderFilters();
    renderGrid();
    renderPlanBadge();
    if (state.tab === "plan") renderPlan();
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

function togglePantry(item) {
  if (state.have.includes(item)) {
    state.have = state.have.filter((value) => value !== item);
  } else {
    state.have = [...state.have, item];
  }
  renderPantry();
  renderGrid();
}

els.search.addEventListener("input", () => {
  state.query = els.search.value;
  renderGrid();
});

els.pantrySearch.addEventListener("input", () => {
  state.pantryQuery = els.pantrySearch.value;
  renderPantry();
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
  state.meal = "all";
  state.cuisine = "all";
  state.tag = "all";
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
els.addRecipeBtn.addEventListener("click", openAddRecipe);

els.tabs.forEach((btn) => {
  btn.addEventListener("click", () => setTab(btn.dataset.tab));
});

document.addEventListener("click", (event) => {
  const pantry = event.target.closest("[data-pantry]");
  if (pantry) {
    togglePantry(pantry.dataset.pantry);
    return;
  }
  const chip = event.target.closest(".chip");
  if (chip && chip.dataset.kind) {
    state[chip.dataset.kind] = chip.dataset.value;
    renderFilters();
    renderGrid();
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
    case "toggle-plan":
      event.stopPropagation();
      togglePlan(id);
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
      state.tag = actionEl.dataset.tag;
      renderFilters();
      renderGrid();
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
    case "pick-add-cuisine": {
      const input = document.getElementById("add-cuisine");
      if (input) input.value = actionEl.dataset.cuisine;
      break;
    }
    case "clear-plan":
      state.checkedItems.clear();
      clearPlan();
      break;
    default:
      break;
  }
});

document.addEventListener("change", (event) => {
  const checkbox = event.target.closest('.grocery-item input[type="checkbox"]');
  if (!checkbox) return;
  const line = checkbox.dataset.line;
  if (state.checkedItems.has(line)) {
    state.checkedItems.delete(line);
  } else {
    state.checkedItems.add(line);
  }
  renderPlan();
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
