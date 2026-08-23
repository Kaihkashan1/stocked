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

const state = {
  recipes: [],
  pantryGroups: [],
  meal: "all",
  cuisine: "all",
  query: "",
  have: [],
  pantryQuery: "",
};

const els = {
  search: document.getElementById("search"),
  meals: document.getElementById("meal-filters"),
  cuisines: document.getElementById("cuisine-filters"),
  pantrySearch: document.getElementById("pantry-search"),
  pantrySelected: document.getElementById("pantry-selected"),
  pantryOptions: document.getElementById("pantry-options"),
  grid: document.getElementById("grid"),
  status: document.getElementById("status"),
  drawer: document.getElementById("drawer"),
  detail: document.getElementById("recipe-detail"),
  close: document.getElementById("close-drawer"),
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
  maybeOpenFromHash();
}

function renderFilters() {
  const meals = ["all", ...Object.keys(MEAL_LABELS)];
  els.meals.innerHTML = meals
    .map((meal) => chip("meal", meal, meal === "all" ? "All meals" : MEAL_LABELS[meal]))
    .join("");

  const cuisines = ["all", ...unique(state.recipes.map((recipe) => recipe.cuisine))];
  els.cuisines.innerHTML = cuisines
    .map((cuisine) => chip("cuisine", cuisine, cuisine === "all" ? "All cuisines" : cuisine))
    .join("");
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
    if (state.meal !== "all" && recipe.meal !== state.meal) continue;
    if (state.cuisine !== "all" && recipe.cuisine !== state.cuisine) continue;
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
  const letter = (recipe.title || "?").slice(0, 1).toUpperCase();
  const thumb = recipe.thumbnail
    ? `<img src="${escapeAttr(recipe.thumbnail)}" alt="" onerror="this.replaceWith(Object.assign(document.createElement('div'), {className:'thumb-letter', textContent:'${escapeAttr(letter)}'}))">`
    : `<div class="thumb-letter">${escapeHtml(letter)}</div>`;
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
  return `
    <button class="card" type="button" data-id="${recipe.id}">
      <div class="thumb">${thumb}</div>
      <div class="card-body">
        <h2>${escapeHtml(recipe.title)}</h2>
        <div class="meta">${tags.join("")}</div>
      </div>
    </button>`;
}

function openRecipe(id) {
  const recipe = state.recipes.find((item) => String(item.id) === String(id));
  if (!recipe) return;
  location.hash = `#recipe/${recipe.id}`;
  els.detail.innerHTML = recipeHtml(recipe);
  els.drawer.hidden = false;
}

function recipeHtml(recipe) {
  const bits = [
    recipe.cuisine,
    MEAL_LABELS[recipe.meal] || recipe.meal,
    recipe.servings ? `${recipe.servings} servings` : null,
    recipe.time,
  ].filter(Boolean);
  const tags = (recipe.tags || []).map((tag) => `<span class="pill">${escapeHtml(tag)}</span>`).join("");
  const ingredients = (recipe.ingredients || [])
    .map((item) => `<li>${escapeHtml(item)}</li>`)
    .join("");
  const steps = (recipe.steps || [])
    .map((item) => `<li>${escapeHtml(item)}</li>`)
    .join("");
  const source = recipe.source
    ? `<p><a href="${escapeAttr(recipe.source)}" target="_blank" rel="noopener">Original post</a></p>`
    : "";
  return `
    <div class="recipe">
      <p class="eyebrow">${escapeHtml(bits.join(" · "))}</p>
      <h2 id="recipe-title">${escapeHtml(recipe.title)}</h2>
      <div class="meta">${tags}</div>
      <h3>Ingredients</h3>
      <ul>${ingredients || "<li>None listed</li>"}</ul>
      <h3>Steps</h3>
      <ol>${steps || "<li>None listed</li>"}</ol>
      ${source}
    </div>`;
}

function closeDrawer() {
  els.drawer.hidden = true;
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
  const card = event.target.closest(".card");
  if (card) openRecipe(card.dataset.id);
});

els.close.addEventListener("click", closeDrawer);
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
