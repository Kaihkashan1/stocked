const STAPLES = new Set(["salt", "water", "oil", "pepper", "black pepper", "sugar"]);

// Suggested chips. Gemini still picks from this list; add/edit can type more.
const RECIPE_TAGS = ["mom's recipes", "veg", "non-veg", "my recipes", "high protein", "airfryer"];
const MAX_RECIPE_TAG_LENGTH = 32;
const MAX_RECIPE_TAGS = 24;
const COURSES = ["Main course", "Appetizers", "Desserts", "Dips"];
const SOURCE_CATEGORIES = [
  { id: "instagram", labelKey: "Instagram" },
  { id: "link", labelKey: "Link" },
  { id: "photo", labelKey: "Photo" },
  { id: "typedIn", labelKey: "Typed in" },
];

function isPhotoImportSource(item) {
  const source = String(item?.source || "").trim().toLowerCase();
  if (source === "(photo)" || source === "photo") return true;
  return Boolean(item?.photo_url);
}

function recipeSourceCategory(recipe) {
  if (isPhotoImportSource(recipe)) return "photo";
  const source = String(recipe?.source || "").trim();
  let host = "";
  try {
    if (source) host = new URL(source, "https://placeholder.invalid").hostname.toLowerCase();
  } catch {
    host = "";
  }
  if (!host || host === "placeholder.invalid") return "typedIn";
  if (host.includes("instagram.com")) return "instagram";
  return "link";
}

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
  "oz", "ounce", "ounces", "floz", "lb", "lbs", "pound", "pounds",
  "clove", "cloves", "slice", "slices", "pinch", "pinches",
  "can", "cans", "pack", "packs", "packet", "packets",
  "piece", "pieces", "pc", "pcs", "handful", "handfuls",
]);

// Fallback category lists for the Cupboard/Medicine add forms, used only
// until the real list arrives from the server (state.pantryInventoryCategories
// / state.medicineCategories start empty, so opening "+ Add" right after
// switching tabs — before that fetch resolves — would otherwise show just
// "Other"). Mirrors app/match.py's AISLE_CATEGORIES and
// app/store.py's MEDICINE_CATEGORIES.
const DEFAULT_PANTRY_CATEGORIES = [
  "Sauces & condiments", "Meat", "Seafood", "Dairy & eggs", "Nuts & seeds",
  "Herbs & spices", "Grains & pasta", "Legumes", "Fruit", "Vegetables", "Other",
];
const DEFAULT_MEDICINE_CATEGORIES = [
  "Pain relief", "Fever & cold", "Cough & throat", "Allergy", "Digestive",
  "Skin & topical", "Eye & ear", "Antibiotics", "Vitamins & supplements",
  "First aid", "Prescription", "Other",
];

const LOG_PAGE_SIZE = 5;
const SECRET_KEY = "recipeBox.secret";
const HAVE_KEY = "recipeBox.have";
const RECIPES_CACHE_KEY = "recipeBox.recipesCache";
const VIEW_MODE_KEY = "recipeBox.viewMode";

function loadViewMode() {
  return localStorage.getItem(VIEW_MODE_KEY) === "grid" ? "grid" : "list";
}

const state = {
  recipes: [],
  pantryGroups: [],
  tags: new Set(),
  knownTags: [],
  query: "",
  have: loadHave(),
  favoritesOnly: false,
  sort: "recent",
  viewMode: loadViewMode(),
  sourceFilters: new Set(),
  openRecipeId: null,
  editingId: null,
  addingRecipe: false,
  usage: null,
  importLog: undefined,
  logFilter: "all",
  logShown: 5,
  pendingPhoto: null,
  pendingPhotoURL: null,
  revealedLogKeys: new Set(),
  copiedLogKey: null,
  settingsSecretDraft: "",
  devSettingsOpen: false,
  view: "recipes",
  pantryInventory: [],
  pantryInventoryCategories: [],
  pantryInventoryLoaded: false,
  cupboardSegment: "groceries",
  shopSegment: "shop",
  packSegment: "take_to_india",
  toBuy: [],
  toBuyLoaded: false,
  medicines: [],
  medicineCategories: [],
  medicinesLoaded: false,
};

const els = {
  search: document.getElementById("search"),
  searchSuggest: document.getElementById("search-suggest"),
  tagFilters: document.getElementById("tag-filters"),
  sourceFilters: document.getElementById("source-filters"),
  haveChips: document.getElementById("have-chips"),
  favoritesToggle: document.getElementById("favorites-toggle"),
  filtersBtn: document.getElementById("filters-btn"),
  viewModeBtn: document.getElementById("view-mode-btn"),
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
  cameraInput: document.getElementById("camera-input"),
  offlineBanner: document.getElementById("offline-banner"),
  viewTabs: document.getElementById("view-tabs"),
  searchRow: document.getElementById("search-row"),
  recipesView: document.getElementById("recipes-view"),
  cupboardView: document.getElementById("cupboard-view"),
  shopView: document.getElementById("shop-view"),
  packView: document.getElementById("pack-view"),
  cupboardList: document.getElementById("cupboard-list"),
  cupboardStatus: document.getElementById("cupboard-status"),
  cupboardSearch: document.getElementById("cupboard-search"),
  cupboardKicker: document.getElementById("cupboard-kicker"),
  cupboardAddBtn: document.getElementById("cupboard-add-btn"),
  cupboardSegments: document.getElementById("cupboard-segments"),
  cupboardStockSearchWrap: document.getElementById("cupboard-stock-search-wrap"),
  cupboardMedicinesSearchWrap: document.getElementById("cupboard-medicines-search-wrap"),
  toBuySearch: document.getElementById("to-buy-search"),
  toBuyList: document.getElementById("to-buy-list"),
  shopKicker: document.getElementById("shop-kicker"),
  shopStatus: document.getElementById("shop-status"),
  shopSegments: document.getElementById("shop-segments"),
  shopAddBtn: document.getElementById("shop-add-btn"),
  packKicker: document.getElementById("pack-kicker"),
  packStatus: document.getElementById("pack-status"),
  packSegments: document.getElementById("pack-segments"),
  packAddBtn: document.getElementById("pack-add-btn"),
  packSearch: document.getElementById("pack-search"),
  packList: document.getElementById("pack-list"),
  medicinesList: document.getElementById("medicines-list"),
  medicinesStatus: document.getElementById("medicines-status"),
  medicinesSearch: document.getElementById("medicines-search"),
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
    const [response, toBuyResponse] = await Promise.all([
      fetch("/api/recipes", { cache: "no-store" }),
      fetch("/api/to-buy", { cache: "no-store" }).catch(() => null),
    ]);
    if (!response.ok) {
      if (!hadCache) els.status.textContent = t("couldNotLoad");
      else setOfflineBanner(true);
      return;
    }
    const data = await response.json();
    applyRecipePayload(data);
    persistRecipesCache(data);
    setOfflineBanner(false);
    try {
      if (toBuyResponse && toBuyResponse.ok) {
        const buy = await toBuyResponse.json();
        state.toBuy = Array.isArray(buy.items) ? buy.items : [];
        state.toBuyLoaded = true;
      }
    } catch {
      // Recipes still load if the shopping list request is malformed.
    }
    renderFilters();
    renderGrid();
    maybeOpenFromHash();
    await fetchHave();
    renderFilters();
    renderGrid();
    renderShopChrome();
    renderToBuy();
    if (state.openRecipeId != null) refreshOpenRecipe();
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

async function createRecipeRequest(draft, photo) {
  const headers = authHeaders();
  let response;
  if (photo) {
    const formData = new FormData();
    formData.append("recipe", JSON.stringify(draft));
    formData.append("photo", photo, "photo.jpg");
    response = await fetch("/api/recipes", { method: "POST", headers, body: formData });
  } else {
    response = await fetch("/api/recipes", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(draft),
    });
  }
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

function isSettingsOpen() {
  return !els.drawer.hidden && state.addingRecipe === false && state.openRecipeId == null && state.editingId == null;
}

function captureSettingsDraft() {
  const input = document.getElementById("settings-secret");
  if (input) state.settingsSecretDraft = input.value;
}

function openSettings() {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  state.devSettingsOpen = false;
  state.importLog = undefined;
  state.logFilter = "all";
  state.logShown = LOG_PAGE_SIZE;
  state.revealedLogKeys = new Set();
  state.copiedLogKey = null;
  state.settingsSecretDraft = localStorage.getItem(SECRET_KEY) || "";
  renderSettings();
  els.drawer.hidden = false;
  fetchUsage().then((usage) => {
    state.usage = usage;
    if (isSettingsOpen()) renderSettings();
  });
  fetchImportLog().then((rows) => {
    state.importLog = rows;
    if (isSettingsOpen()) renderSettings();
  });
}

function renderSettings() {
  captureSettingsDraft();
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

async function fetchImportLog() {
  try {
    const response = await fetch("/api/import-log", { headers: authHeaders() });
    if (!response.ok) return null;
    const data = await response.json();
    return Array.isArray(data.imports) ? data.imports : [];
  } catch {
    return null;
  }
}

function logHeadline(row) {
  return String(row.reason || "").replace(/\s*\((high|medium|low)\)\s*$/i, "").trim();
}

function logModelName(row) {
  if (row.model) return String(row.model);
  return row.used_backup ? "gemini-3.5-flash-lite" : "gemini-3.6-flash";
}

function logRowKey(row, index) {
  return `${index}|${row.timestamp || ""}|${row.url || ""}|${row.status || ""}`;
}

function importLogRowHtml(row, index) {
  const isError = row.status === "error";
  const key = logRowKey(row, index);
  const detailsOpen = state.revealedLogKeys.has(key);
  const mark = isError
    ? `<span class="log-mark err" aria-label="${escapeAttr(t("errorLogs"))}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>
      </span>`
    : `<span class="log-mark ok" aria-label="${escapeAttr(t("savedLogs"))}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>
      </span>`;
  const headline = logHeadline(row) || (isError ? t("errorLogs") : t("savedLogs"));
  const isPhoto = !row.url || row.url === "(photo)" || row.url === "photo";
  const photoChip = isPhoto
    ? `<span class="log-photo-chip">${escapeHtml(t("Photo"))}</span>`
    : "";
  let detailsBody = "";
  if (detailsOpen) {
    const source = isPhoto
      ? `<div class="import-log-url">${escapeHtml(t("Photo"))}</div>`
      : `<div class="import-log-link-row">
          <a class="import-log-url" href="${escapeAttr(row.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(row.url)}</a>
          <button class="log-copy" type="button" data-action="copy-log-url" data-url="${escapeAttr(row.url)}" data-key="${escapeAttr(key)}" aria-label="${escapeAttr(t("copyLink"))}">${escapeHtml(state.copiedLogKey === key ? t("copied") : t("copy"))}</button>
        </div>`;
    detailsBody = `<div class="import-log-details-body">
      <div class="import-log-model">${escapeHtml(logModelName(row))}</div>
      ${source}
    </div>`;
  }
  return `<li class="import-log-row">
    <div class="import-log-meta">
      ${mark}
      <span>${escapeHtml(row.timestamp || "")}</span>
      ${photoChip}
    </div>
    <div class="import-log-title">${escapeHtml(headline)}</div>
    <button class="import-log-details-toggle${detailsOpen ? " open" : ""}" type="button" data-action="toggle-log-details" data-key="${escapeAttr(key)}">
      ${escapeHtml(t("additionalDetails"))}
    </button>
    ${detailsBody}
  </li>`;
}

function importLogHtml() {
  const filter = state.logFilter || "all";
  const chips = ["all", "saved", "errors"]
    .map((key) => {
      const label = key === "all" ? t("allLogs") : key === "saved" ? t("savedLogs") : t("errorLogs");
      const action = key === "all" ? "all" : key;
      return `<button class="chip${filter === action ? " active" : ""}" type="button" data-action="log-filter" data-filter="${action}">${escapeHtml(label)}</button>`;
    })
    .join("");
  let body = `<div class="log-filters chips">${chips}</div>`;
  if (state.importLog === undefined) {
    body += `<p class="field-note">${escapeHtml(t("loadingLogs"))}</p>`;
  } else if (state.importLog === null) {
    body += `<p class="field-note">${escapeHtml(t("couldntLoadLogs"))}</p>`;
  } else {
    const filtered = state.importLog.filter((row) => {
      if (filter === "saved") return row.status === "saved" || row.status === "duplicate";
      if (filter === "errors") return row.status === "error";
      return true;
    });
      if (!state.importLog.length) {
        body += `<p class="field-note">${escapeHtml(t("noImportLogs"))}</p>`;
      } else if (!filtered.length) {
        body += `<p class="field-note">${escapeHtml(t("noMatchingLogs"))}</p>`;
      } else {
        const shown = Math.min(Number(state.logShown) || LOG_PAGE_SIZE, filtered.length);
        state.logShown = shown;
        const pageRows = filtered.slice(0, shown);
        body += `<ul class="import-log">${pageRows.map((row, index) => importLogRowHtml(row, index)).join("")}</ul>`;
        if (shown < filtered.length) {
          body += `<button class="log-more" type="button" data-action="log-more">${escapeHtml(t("showMoreLogs"))}</button>`;
        }
      }
  }
  return `
    <div class="logs-section">
      <div class="eyebrow">${escapeHtml(t("logs"))}</div>
      ${body}
    </div>`;
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
  const secretDraft = state.settingsSecretDraft != null ? state.settingsSecretDraft : secret;
  const serverUrl = window.location.origin;
  const devBody = state.devSettingsOpen
    ? `<div class="dev-settings">
        <label class="field">
          <span>${escapeHtml(t("server"))}</span>
          <input id="settings-server" type="url" value="${escapeAttr(serverUrl)}" readonly>
          <p class="field-note">${escapeHtml(t("serverFootnote"))}</p>
        </label>
        <label class="field">
          <span>${escapeHtml(t("editKey"))}</span>
          <input id="settings-secret" class="settings-secret" type="password" autocomplete="off" value="${escapeAttr(secretDraft)}" placeholder="${escapeAttr(t("editKey"))}">
          <p class="field-note">${escapeHtml(t("editKeyFootnote"))}</p>
        </label>
        <button class="pill-btn primary settings-save" type="button" data-action="save-settings">${escapeHtml(t("saveAndReload"))}</button>
      </div>`
    : "";
  return `
    <div class="drawer-actions settings-bar">
      <button class="settings-close" type="button" data-action="close-drawer">${escapeHtml(t("close"))}</button>
    </div>
    <div class="recipe recipe-body">
      <h2 class="settings-title">${escapeHtml(t("settings"))}</h2>
      ${limitsHtml}
      <button class="dev-toggle" type="button" data-action="toggle-developer">
        <span class="eyebrow">${escapeHtml(t("developer"))}</span>
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round" style="transform:rotate(${chevron})"><path d="M6 9l6 6 6-6"></path></svg>
      </button>
      ${devBody}
      ${importLogHtml()}
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

function peelGluedAmountUnit(token) {
  const cleaned = token.replace(/^[,;]+|[,;]+$/g, "");
  const match = cleaned.match(/^([0-9¼½¾⅓⅔⅛⅜]+(?:[/.][0-9]+)?)(fl\.?oz|floz|ounces?|oz)$/i);
  if (!match) return null;
  return { amount: match[1], unit: match[2] };
}

function isFluidOuncePrefix(token) {
  return token === "fl" || token === "fl." || token === "fluid";
}

function isOunceUnit(token) {
  const unit = token.replace(/[.,;]+$/g, "").toLowerCase();
  return unit === "oz" || unit === "ounce" || unit === "ounces" || unit === "floz";
}

const FRACTION_GLYPHS = { "¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3, "⅛": 0.125, "⅜": 0.375 };

function parseQuantityNumber(token) {
  const cleaned = token.replace(/^[,;]+|[,;]+$/g, "");
  if (!cleaned || cleaned.includes("-")) return null;
  if (cleaned.includes("/")) {
    const parts = cleaned.split("/");
    if (parts.length !== 2) return null;
    const numerator = Number(parts[0]);
    const denominator = Number(parts[1]);
    if (!numerator || !denominator) return null;
    return numerator / denominator;
  }
  let i = 0;
  let numStr = "";
  while (i < cleaned.length && /[0-9.]/.test(cleaned[i])) {
    numStr += cleaned[i];
    i += 1;
  }
  const whole = numStr ? Number(numStr) : 0;
  const glyph = cleaned[i];
  if (glyph && FRACTION_GLYPHS[glyph] != null) return whole + FRACTION_GLYPHS[glyph];
  return numStr ? whole : null;
}

const VOLUME_OUNCE_INGREDIENT = /\b(water|milk|buttermilk|oil|juice|stock|broth|vinegar|wine|beer|vodka|rum|gin|whiskey|whisky|brandy|liqueur|espresso|coconut milk|soy sauce|fish sauce|hot sauce|worcestershire|heavy cream|whipping cream|half[- ]and[- ]half|maple syrup)\b/i;
const METRIC_UNITS = new Set(["g", "gram", "grams", "kg", "ml", "l", "litre", "litres", "liter", "liters"]);

function metricFromOunces(quantity, ingredient) {
  const words = (quantity || "").trim().split(/\s+/).filter(Boolean);
  if (words.length < 2) return quantity;
  const value = parseQuantityNumber(words[0]);
  if (value == null) return quantity;
  const unit = words
    .slice(1)
    .map((word) => word.replace(/[.,;]+$/g, "").toLowerCase())
    .join(" ")
    .replace(/\./g, "");
  if (METRIC_UNITS.has(unit)) return quantity;
  const fluid = unit === "floz" || unit.startsWith("fl ") || unit.startsWith("fluid ");
  const ounce = unit === "oz" || unit === "ounce" || unit === "ounces";
  if (!fluid && !ounce) return quantity;
    if (fluid || VOLUME_OUNCE_INGREDIENT.test(ingredient || "")) {
      const ml = value * 29.5735295625;
      const rounded = ml >= 10 ? Math.round(ml / 5) * 5 : Math.round(ml);
      return `${rounded} ml`;
    }
  return `${Math.round(value * 28.349523125)} g`;
}

function looksLikeSectionName(name) {
  const text = (name || "").trim();
  if (!text || text.length > 40) return false;
  if (/\d/.test(text)) return false;
  const words = text.split(/\s+/).filter(Boolean);
  return words.length >= 1 && words.length <= 4;
}

function splitIngredientSection(line) {
  const text = (line || "").trim();
  if (!text) return { section: null, item: "" };
  const markdown = text.match(/^#{1,3}\s+(.+)$/);
  if (markdown) {
    const name = markdown[1].trim().replace(/:+$/, "");
    if (name) return { section: name, item: null };
  }
  const heading = text.match(/^([^:]{1,40}):\s*$/);
  if (heading && looksLikeSectionName(heading[1])) {
    return { section: heading[1].trim(), item: null };
  }
    prefixed = text.match(/^([^:]{1,40}):\s+(.+)$/);
  if (prefixed && looksLikeSectionName(prefixed[1])) {
    return { section: prefixed[1].trim(), item: prefixed[2].trim() };
  }
  const qtySplit = splitIngredientQuantity(text);
  if (qtySplit.quantity) {
    const inner = qtySplit.text.match(/^([^:]{1,40}):\s+(.+)$/);
    if (inner && looksLikeSectionName(inner[1])) {
      const item = inner[2].trim();
      return {
        section: inner[1].trim(),
        item: item ? `${qtySplit.quantity} ${item}` : qtySplit.quantity,
      };
    }
  }
  return { section: null, item: text };
}

function ingredientItemLi(line, recipeId) {
  const { quantity, text } = splitIngredientQuantity(line);
  const shown = quantity ? metricFromOunces(quantity, text) : "";
  const qtyChip = shown ? `<span class="qty">${escapeHtml(shown)}</span>` : "";
  const nameClass = quantity ? "" : " class=\"ingredient-plain\"";
  const toggle = recipeId == null ? "" : toBuyToggleHtml(text, shown, recipeId);
  return `<li${nameClass}>${qtyChip}<span>${escapeHtml(text)}</span>${toggle}</li>`;
}

function ingredientsHtml(lines, recipeId) {
  const list = lines || [];
  if (!list.length) {
    return `<ul class="ingredients"><li>${escapeHtml(t("noneListed"))}</li></ul>`;
  }
  const parts = [];
  let heading = null;
  const sameHeading = (a, b) => (a || "").toLowerCase() === (b || "").toLowerCase();
  const pushHeading = (label) => {
    const first = parts.length === 0;
    parts.push(`<li class="ingredient-section${first ? " first" : ""}">${escapeHtml(label)}</li>`);
  };
  for (const line of list) {
    const parsed = splitIngredientSection(line);
    if (parsed.item === null && parsed.section) {
      heading = parsed.section;
      pushHeading(parsed.section);
      continue;
    }
    if (parsed.section) {
      if (!sameHeading(heading, parsed.section)) {
        heading = parsed.section;
        pushHeading(parsed.section);
      }
      parts.push(ingredientItemLi(parsed.item, recipeId));
      continue;
    }
    parts.push(ingredientItemLi(parsed.item, recipeId));
  }
  return `<ul class="ingredients">${parts.join("") || `<li>${escapeHtml(t("noneListed"))}</li>`}</ul>`;
}

function splitIngredientQuantity(line) {
  const trimmed = line.trim();
  const words = trimmed.split(/\s+/).filter(Boolean);
  if (words.length && peelGluedAmountUnit(words[0])) {
    const glued = peelGluedAmountUnit(words[0]);
    words.splice(0, 1, glued.amount, glued.unit);
  }
  if (!words.length || !looksLikeQuantityToken(words[0])) {
    return { quantity: null, text: trimmed };
  }
  const quantityParts = [words[0]];
  let consumed = 1;
  if (words.length > 1) {
    const second = words[1].replace(/[.,;]+$/, "").toLowerCase();
    if (isFluidOuncePrefix(second) && words.length > 2 && isOunceUnit(words[2])) {
      quantityParts.push(words[1], words[2]);
      consumed = 3;
    } else if (INGREDIENT_UNITS.has(second)) {
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

  if (els.sourceFilters) {
    els.sourceFilters.innerHTML = SOURCE_CATEGORIES.map(({ id, labelKey }) => {
      const active = state.sourceFilters.has(id);
      return `<button class="chip${active ? " active" : ""}" type="button" data-action="toggle-source-filter" data-source="${escapeAttr(id)}">${escapeHtml(t(labelKey))}${active ? " ×" : ""}</button>`;
    }).join("");
  }

  document
    .querySelectorAll("#sort-options .chip")
    .forEach((chip) => chip.classList.toggle("active", chip.dataset.sort === state.sort));

  const activeCount = [state.tags.size > 0, state.favoritesOnly, state.have.length > 0, state.sourceFilters.size > 0].filter(Boolean).length;
  els.filtersBtn.classList.toggle("active", activeCount > 0);
  els.filtersBtn.textContent = "";
  els.filtersBtn.append(filtersIcon(), document.createTextNode(activeCount > 0 ? t("filtersCount", { count: activeCount }) : t("filters")));
}

function filtersIcon() {
  const span = document.createElement("span");
  span.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M7 12h10M10 18h4"/></svg>`;
  return span.firstElementChild;
}

function viewModeIcon(mode) {
  if (mode === "grid") {
    return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3.5" y="3.5" width="7.5" height="7.5" rx="1.8"/><rect x="13" y="3.5" width="7.5" height="7.5" rx="1.8"/><rect x="3.5" y="13" width="7.5" height="7.5" rx="1.8"/><rect x="13" y="13" width="7.5" height="7.5" rx="1.8"/></svg>`;
  }
  return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6.5h16M4 12h16M4 17.5h16"/></svg>`;
}

function applyViewMode() {
  document.querySelectorAll(".grid").forEach((grid) => {
    grid.classList.toggle("view-list", state.viewMode === "list");
    grid.classList.toggle("view-grid", state.viewMode === "grid");
  });
  const next = state.viewMode === "grid" ? "list" : "grid";
  document.querySelectorAll(".view-mode-btn").forEach((btn) => {
    btn.innerHTML = viewModeIcon(next);
    btn.setAttribute("aria-label", t("toggleViewMode"));
  });
}

function toggleViewMode() {
  state.viewMode = state.viewMode === "grid" ? "list" : "grid";
  localStorage.setItem(VIEW_MODE_KEY, state.viewMode);
  applyViewMode();
  renderGrid();
}

function recipeSourceLabel(recipe) {
  const found = SOURCE_CATEGORIES.find((item) => item.id === recipeSourceCategory(recipe));
  return t(found ? found.labelKey : "Typed in");
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

// Reads from the server-grouped catalog (already deduped and collapsed,
// e.g. "spinach leaves" folded into "spinach") rather than recomputing an
// uncollapsed list straight from each recipe's raw pantry field.
function pantryCatalog() {
  return state.pantryGroups.flatMap((group) => group.items);
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

// Prefix-only, unlike namesMatch's anywhere-substring check below: while
// you're still typing, a bare substring match is too eager — "pra" is
// contained in "spray", so every "oil spray"/"cooking spray" item would
// show up in the suggestion row for someone halfway through typing
// "prawn". Matching at the start of the item or of one of its words
// keeps suggestions relevant to what's actually been typed so far.
function pantryQueryMatch(item, needle) {
  if (!needle) return true;
  if (item.startsWith(needle) || needle.startsWith(item)) return true;
  return item.split(" ").some((word) => word.startsWith(needle));
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
    if (state.sourceFilters.size && !state.sourceFilters.has(recipeSourceCategory(recipe))) continue;
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
  const source = state.viewMode === "list"
    ? `<p class="card-source">${escapeHtml(recipeSourceLabel(recipe))}</p>`
    : "";
  return `
    <div class="card" data-id="${recipe.id}">
      <div class="card-actions">
        <button class="card-icon-btn favorite${favoriteActive}" type="button" data-action="toggle-favorite" data-id="${recipe.id}" aria-label="${escapeAttr(t("favorite"))}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="${recipe.favorite ? "currentColor" : "none"}" stroke="currentColor" stroke-width="1.8"><path d="M12 3.6c-2-2.3-5.4-2.6-7.5-.4-2.2 2.2-2.1 5.8.3 8.1L12 18.6l7.2-7.3c2.4-2.3 2.5-5.9.3-8.1-2.1-2.2-5.5-1.9-7.5.4z"/></svg>
        </button>
      </div>
      ${recipe.photo_url ? `<img class="card-photo" src="${escapeAttr(recipe.photo_url)}" alt="">` : ""}
      <button class="card-body" type="button" data-action="open-recipe" data-id="${recipe.id}" style="text-align:left; background:none; border:none; cursor:pointer; padding:1.1rem; font:inherit; color:inherit;">
        ${source}
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
    setPendingPhoto(blob);
    openAddRecipe(extraction);
  } catch (err) {
    window.alert(t("couldntReadPhoto", { error: err.message }));
  } finally {
    showPhotoLoading(false);
  }
}

function setPendingPhoto(blob) {
  if (state.pendingPhotoURL) URL.revokeObjectURL(state.pendingPhotoURL);
  state.pendingPhoto = blob || null;
  state.pendingPhotoURL = blob ? URL.createObjectURL(blob) : null;
}

function openAddRecipe(prefill) {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = true;
  if (!prefill) setPendingPhoto(null);
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
  const ingredients = ingredientsHtml(recipe.ingredients || [], recipe.id);
  const steps = (recipe.steps || [])
    .map((item, index) => `<li><span class="step-num">${index + 1}</span><span>${escapeHtml(item)}</span></li>`)
    .join("");
  const originalPostItem = recipe.source && !isPhotoImportSource(recipe)
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
      ${ingredients}
      <h3>${escapeHtml(t("steps"))}</h3>
      <ol class="steps">${steps || `<li>${escapeHtml(t("noneListed"))}</li>`}</ol>
      ${notesSection}
      ${tags ? `<div class="meta">${tags}</div>` : ""}
      ${recipe.photo_url ? `<img class="recipe-photo" src="${escapeAttr(recipe.photo_url)}" alt="">` : ""}
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
      <button class="pill-btn primary" type="button" data-action="save-add-recipe">${escapeHtml(t("save"))}</button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(t(prefill ? "fromAPhoto" : "addRecipeTitle"))}</h2>
      <input type="hidden" id="add-source" value="${prefill ? "photo" : ""}">
      ${prefill ? `<p style="margin:-0.4rem 0 1.2rem; color:var(--ink-soft); font-size:0.85rem;">${escapeHtml(t("photoPrefillHint"))}</p>` : ""}
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
      ${prefill && state.pendingPhotoURL ? `<img class="recipe-photo add-photo-preview" src="${escapeAttr(state.pendingPhotoURL)}" alt="">` : ""}
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
  const saveBtns = document.querySelectorAll('[data-action="save-add-recipe"]');

  const title = titleInput.value.trim();
  if (!title) {
    errorEl.textContent = t("titleEmpty");
    errorEl.hidden = false;
    titleInput.focus();
    titleInput.scrollIntoView({ block: "center", behavior: "smooth" });
    return;
  }

  const draft = {
    title,
    ingredients: linesFrom(ingredientsInput.value),
    steps: linesFrom(stepsInput.value),
    course: courseInput.value || "Main course",
    tags: tagsInput.value.split(",").map((tag) => tag.trim()).filter(Boolean),
    notes: notesInput.value.trim(),
    source: document.getElementById("add-source")?.value || "",
  };
  const fromPhoto = Boolean(state.pendingPhoto) || isPhotoImportSource(draft);
  if (fromPhoto) draft.source = "photo";

  saveBtns.forEach((btn) => {
    btn.disabled = true;
    btn.textContent = t("saving");
  });
  try {
    const created = await createRecipeRequest(draft, fromPhoto ? state.pendingPhoto : null);
    created.searchBlob = computeSearchBlob(created);
    state.recipes.unshift(created);
    state.addingRecipe = false;
    closeDrawer();
    renderFilters();
    renderGrid();
  } catch (err) {
    errorEl.textContent = t("couldntSave", { error: err.message });
    errorEl.hidden = false;
    saveBtns.forEach((btn) => {
      btn.disabled = false;
      btn.textContent = t("save");
    });
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
  setPendingPhoto(null);
  if (location.hash.startsWith("#recipe/")) {
    history.replaceState(null, "", location.pathname);
  }
}

function maybeOpenFromHash() {
  const recipeMatch = location.hash.match(/^#recipe\/(\d+)/);
  if (recipeMatch) {
    openRecipe(recipeMatch[1]);
    return;
  }
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

// ---------- Cupboard / Medicines tabs ----------
// Both are a flat list of items grouped by category, with the same
// fetch/save/delete shape as the backend's pantry_inventory/medicines
// AppState keys (see app/store.py) — one generic module instead of two
// near-identical copies. Only the fields shown per item, and the add/edit
// form's fields, differ between the two (see INVENTORY_KINDS below).
const INVENTORY_KINDS = {
  cupboard: {
    apiPath: "/api/pantry-inventory",
    itemsKey: "pantryInventory",
    categoriesKey: "pantryInventoryCategories",
    loadedKey: "pantryInventoryLoaded",
    listEl: () => els.cupboardList,
    statusEl: () => els.cupboardStatus,
    searchEl: () => els.cupboardSearch,
    emptyLabel: "cupboardEmpty",
    countOneKey: "cupboardCountOne",
    countOtherKey: "cupboardCountOther",
    units: ["pcs", "g", "kg"],
    statuses: ["unopened", "open"],
    defaultUnit: "pcs",
    defaultStatus: "unopened",
  },
  medicine: {
    apiPath: "/api/medicines",
    itemsKey: "medicines",
    categoriesKey: "medicineCategories",
    loadedKey: "medicinesLoaded",
    listEl: () => els.medicinesList,
    statusEl: () => els.medicinesStatus,
    searchEl: () => els.medicinesSearch,
    emptyLabel: "medicinesEmpty",
    countOneKey: "medicinesCountOne",
    countOtherKey: "medicinesCountOther",
    units: ["pills", "ml", "mg", "pcs"],
    // Same meaning as Cupboard's: has this strip/bottle been opened yet.
    statuses: ["unopened", "open"],
    defaultUnit: "pills",
    defaultStatus: "unopened",
  },
};

function switchView(view) {
  state.view = view;
  els.recipesView.hidden = view !== "recipes";
  els.cupboardView.hidden = view !== "cupboard";
  els.shopView.hidden = view !== "shop";
  if (els.packView) els.packView.hidden = view !== "pack";
  els.searchRow.hidden = view !== "recipes";
  if (view !== "recipes") els.searchSuggest.hidden = true;
  els.viewTabs.querySelectorAll("[data-view]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.view === view);
  });
  if (view === "cupboard") {
    if (!state.pantryInventoryLoaded) loadInventory("cupboard");
    if (!state.medicinesLoaded) loadInventory("medicine");
    renderCupboardChrome();
  }
  if (view === "shop" || view === "pack") {
    if (!state.toBuyLoaded) loadToBuy();
    if (!state.pantryInventoryLoaded) loadInventory("cupboard");
    if (!state.medicinesLoaded) loadInventory("medicine");
    renderChecklistChrome();
    renderToBuy();
  }
}

async function loadInventory(kind) {
  const config = INVENTORY_KINDS[kind];
  state[config.loadedKey] = true;
  try {
    const response = await fetch(config.apiPath);
    if (!response.ok) return;
    const data = await response.json();
    state[config.itemsKey] = Array.isArray(data.items) ? data.items : [];
    state[config.categoriesKey] = Array.isArray(data.categories) ? data.categories : [];
    renderInventory(kind);
  } catch {
    config.statusEl().textContent = t("couldNotLoad");
  }
}

async function putInventory(kind, items) {
  const config = INVENTORY_KINDS[kind];
  const response = await fetch(config.apiPath, {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ items }),
  });
  if (!response.ok) throw await errorForResponse(response);
  return response.json();
}

// Optimistic like togglePantry: update locally and re-render first, push
// the whole list, then reconcile with whatever the server actually saved
// (or roll back on failure).
async function saveInventoryItem(kind, item) {
  const config = INVENTORY_KINDS[kind];
  const previous = state[config.itemsKey];
  const index = previous.findIndex((existing) => existing.id === item.id);
  const next = index === -1 ? [...previous, item] : previous.map((existing, i) => (i === index ? item : existing));
  state[config.itemsKey] = next;
  renderInventory(kind);
  try {
    const data = await putInventory(kind, next);
    state[config.itemsKey] = data.items || next;
    if (data.categories) state[config.categoriesKey] = data.categories;
    closeDrawer();
  } catch (err) {
    state[config.itemsKey] = previous;
    window.alert(t("couldntSave", { error: err.message }));
  }
  renderInventory(kind);
}

async function deleteInventoryItem(kind, id) {
  const config = INVENTORY_KINDS[kind];
  const previous = state[config.itemsKey];
  state[config.itemsKey] = previous.filter((item) => item.id !== id);
  renderInventory(kind);
  try {
    const data = await putInventory(kind, state[config.itemsKey]);
    state[config.itemsKey] = data.items || state[config.itemsKey];
  } catch (err) {
    state[config.itemsKey] = previous;
    window.alert(t("couldntSave", { error: err.message }));
  }
  renderInventory(kind);
}

function groupInventoryByCategory(items, categories) {
  const buckets = new Map();
  for (const category of categories) buckets.set(category, []);
  for (const item of items) {
    const category = item.category || "Other";
    if (!buckets.has(category)) buckets.set(category, []);
    buckets.get(category).push(item);
  }
  return [...buckets.entries()].filter(([, list]) => list.length);
}

// Expired/expiring-soon gets called out the same way in both tabs — most
// useful for medicines, but equally relevant to anything in the cupboard.
function expiryPillHtml(expiry) {
  if (!expiry) return "";
  const days = Math.ceil((new Date(`${expiry}T00:00:00`) - new Date()) / 86400000);
  if (days < 0) return `<span class="pill danger">${escapeHtml(t("expired"))}</span>`;
  if (days <= 30) return `<span class="pill warm">${escapeHtml(t("expiresInDays", { n: days }))}</span>`;
  return `<span class="pill">${escapeHtml(t("expiresOn", { date: expiry }))}</span>`;
}

function inventorySearchMatch(item, needle) {
  if (!needle) return true;
  if (item.name.toLowerCase().includes(needle)) return true;
  if ((item.category || "").toLowerCase().includes(needle)) return true;
  if (item.purpose && item.purpose.toLowerCase().includes(needle)) return true;
  return false;
}

function renderInventory(kind) {
  renderCupboardChrome();
  const config = INVENTORY_KINDS[kind];
  const items = state[config.itemsKey];
  const needle = (config.searchEl()?.value || "").trim().toLowerCase();
  const visibleItems = needle ? items.filter((item) => inventorySearchMatch(item, needle)) : items;
  const groups = groupInventoryByCategory(visibleItems, state[config.categoriesKey]);
  // Always the total count, like iOS — a search narrows what's shown, not
  // what "items" means.
  config.statusEl().textContent =
    items.length === 1 ? t(config.countOneKey, { n: items.length }) : t(config.countOtherKey, { n: items.length });
  const listEl = config.listEl();
  if (!groups.length) {
    listEl.innerHTML = `<div class="empty">${escapeHtml(needle ? t("inventoryNoMatch") : t(config.emptyLabel))}</div>`;
    return;
  }
  listEl.innerHTML = groups
    .map(
      ([category, groupItems]) => `
    <div class="pantry-group" style="grid-column:1/-1;">
      <h3 class="pantry-heading">${escapeHtml(category)}</h3>
      <div class="grid${state.viewMode === "list" ? " view-list" : " view-grid"}">${groupItems.map((item) => inventoryCardHtml(kind, item)).join("")}</div>
    </div>`
    )
    .join("");
  applyViewMode();
}

function inventoryCardHtml(kind, item) {
  const meta = kind === "cupboard" ? cupboardMetaHtml(item) : medicineMetaHtml(item);
  return `
    <div class="card" data-action="edit-inventory-item" data-kind="${kind}" data-id="${escapeAttr(item.id)}">
      <div class="card-actions">
        <button class="card-icon-btn" type="button" data-action="delete-inventory-item" data-kind="${kind}" data-id="${escapeAttr(item.id)}" aria-label="${escapeAttr(t("delete"))}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13"/></svg>
        </button>
      </div>
      <div class="card-body">
        <h2>${escapeHtml(item.name)}</h2>
        ${meta}
      </div>
    </div>`;
}

function cupboardMetaHtml(item) {
  return `
    <span class="inventory-meta">${escapeHtml(String(item.amount))} ${escapeHtml(item.unit)} · ${escapeHtml(t(item.status))}</span>
    ${item.notes ? `<span class="inventory-meta">${escapeHtml(item.notes)}</span>` : ""}
    <div class="meta">${expiryPillHtml(item.expiry)}</div>`;
}

function medicineMetaHtml(item) {
  return `
    <span class="inventory-meta">${escapeHtml(String(item.amount))} ${escapeHtml(item.unit)} · ${escapeHtml(t(item.status))}</span>
    ${item.purpose ? `<span class="inventory-meta">${escapeHtml(item.purpose)}</span>` : ""}
    ${item.notes ? `<span class="inventory-meta">${escapeHtml(item.notes)}</span>` : ""}
    <div class="meta">${expiryPillHtml(item.expiry)}</div>`;
}

// Grows a textarea to fit its content instead of scrolling inside a fixed
// box — called on input, and once right after a form opens so an existing
// multi-line note starts at full height instead of a tiny scrollable box.
function autoGrowTextarea(el) {
  el.style.height = "auto";
  el.style.height = `${el.scrollHeight}px`;
}

document.addEventListener("input", (event) => {
  if (event.target.classList?.contains("notes-grow")) autoGrowTextarea(event.target);
  const field = event.target.closest("[data-action='to-buy-qty'], [data-action='to-buy-notes']");
  if (!field) return;
  if (field.dataset.action === "to-buy-qty") setToBuyQty(field.dataset.id, field.value);
  if (field.dataset.action === "to-buy-notes") setToBuyNotes(field.dataset.id, field.value);
});

function openAddInventoryItem(kind) {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  els.detail.innerHTML = kind === "cupboard" ? pantryItemFormHtml(null) : medicineFormHtml(null);
  els.drawer.hidden = false;
  els.detail.querySelectorAll(".notes-grow").forEach(autoGrowTextarea);
}

function openEditInventoryItem(kind, id) {
  const config = INVENTORY_KINDS[kind];
  const item = state[config.itemsKey].find((existing) => existing.id === id);
  if (!item) return;
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  els.detail.innerHTML = kind === "cupboard" ? pantryItemFormHtml(item) : medicineFormHtml(item);
  els.drawer.hidden = false;
  els.detail.querySelectorAll(".notes-grow").forEach(autoGrowTextarea);
}

function unitOptionsHtml(units, selected) {
  return units.map((unit) => `<option value="${escapeAttr(unit)}"${unit === selected ? " selected" : ""}>${escapeHtml(unit)}</option>`).join("");
}

function statusOptionsHtml(statuses, selected) {
  return statuses.map((status) => `<option value="${escapeAttr(status)}"${status === selected ? " selected" : ""}>${escapeHtml(t(status))}</option>`).join("");
}

function categoryOptionsHtml(categories, selected) {
  return categories
    .map((category) => `<option value="${escapeAttr(category)}"${category === selected ? " selected" : ""}>${escapeHtml(category)}</option>`)
    .join("");
}

function pantryItemFormHtml(item) {
  const config = INVENTORY_KINDS.cupboard;
  const categories = state.pantryInventoryCategories.length ? state.pantryInventoryCategories : DEFAULT_PANTRY_CATEGORIES;
  const category = item?.category && categories.includes(item.category) ? item.category : categories[0];
  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("cancel"))}
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(item ? t("editItem") : t("addItem"))}</h2>
      <input type="hidden" id="pantry-item-id" value="${escapeAttr(item?.id || "")}">
      <label class="field">
        <span>${escapeHtml(t("name"))}</span>
        <input id="pantry-item-name" value="${escapeAttr(item?.name || "")}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("category"))}</span>
        <select id="pantry-item-category">${categoryOptionsHtml(categories, category)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("amount"))}</span>
        <input id="pantry-item-amount" type="number" min="0" step="any" value="${escapeAttr(item?.amount ?? 1)}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("unit"))}</span>
        <select id="pantry-item-unit">${unitOptionsHtml(config.units, item?.unit || config.defaultUnit)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("status"))}</span>
        <select id="pantry-item-status">${statusOptionsHtml(config.statuses, item?.status || config.defaultStatus)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("expiry"))}</span>
        <input id="pantry-item-expiry" type="date" value="${escapeAttr(item?.expiry || "")}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("notes"))}</span>
        <textarea id="pantry-item-notes" class="notes-grow" rows="3">${escapeHtml(item?.notes || "")}</textarea>
      </label>
      <button class="pill-btn primary" type="button" data-action="save-pantry-item">${escapeHtml(t("save"))}</button>
    </div>`;
}

function saveAddOrEditPantryItem() {
  const name = document.getElementById("pantry-item-name").value.trim();
  if (!name) return;
  const item = {
    id: document.getElementById("pantry-item-id").value || `local-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    name,
    category: document.getElementById("pantry-item-category").value || "Other",
    amount: Number(document.getElementById("pantry-item-amount").value) || 1,
    unit: document.getElementById("pantry-item-unit").value,
    status: document.getElementById("pantry-item-status").value,
    expiry: document.getElementById("pantry-item-expiry").value || null,
    notes: document.getElementById("pantry-item-notes").value.trim(),
  };
  saveInventoryItem("cupboard", item);
}

function medicineFormHtml(item) {
  const config = INVENTORY_KINDS.medicine;
  const categories = state.medicineCategories.length ? state.medicineCategories : DEFAULT_MEDICINE_CATEGORIES;
  const category = item?.category && categories.includes(item.category) ? item.category : categories[0];
  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("cancel"))}
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(item ? t("editMedicine") : t("addMedicine"))}</h2>
      <input type="hidden" id="medicine-id" value="${escapeAttr(item?.id || "")}">
      <label class="field">
        <span>${escapeHtml(t("name"))}</span>
        <input id="medicine-name" value="${escapeAttr(item?.name || "")}" placeholder="${escapeAttr(t("medicineNamePlaceholder"))}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("category"))}</span>
        <select id="medicine-category">${categoryOptionsHtml(categories, category)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("amount"))}</span>
        <input id="medicine-amount" type="number" min="0" step="any" value="${escapeAttr(item?.amount ?? 1)}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("unit"))}</span>
        <select id="medicine-unit">${unitOptionsHtml(config.units, item?.unit || config.defaultUnit)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("status"))}</span>
        <select id="medicine-status">${statusOptionsHtml(config.statuses, item?.status || config.defaultStatus)}</select>
      </label>
      <label class="field">
        <span>${escapeHtml(t("expiry"))}</span>
        <input id="medicine-expiry" type="date" value="${escapeAttr(item?.expiry || "")}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("purpose"))}</span>
        <input id="medicine-purpose" value="${escapeAttr(item?.purpose || "")}" placeholder="${escapeAttr(t("purposePlaceholder"))}">
      </label>
      <label class="field">
        <span>${escapeHtml(t("notes"))}</span>
        <textarea id="medicine-notes" class="notes-grow" rows="3">${escapeHtml(item?.notes || "")}</textarea>
      </label>
      <button class="pill-btn primary" type="button" data-action="save-medicine">${escapeHtml(t("save"))}</button>
    </div>`;
}

function saveAddOrEditMedicine() {
  const name = document.getElementById("medicine-name").value.trim();
  if (!name) return;
  const item = {
    id: document.getElementById("medicine-id").value || `local-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    name,
    category: document.getElementById("medicine-category").value || "Other",
    amount: Number(document.getElementById("medicine-amount").value) || 1,
    unit: document.getElementById("medicine-unit").value,
    status: document.getElementById("medicine-status").value,
    expiry: document.getElementById("medicine-expiry").value || null,
    purpose: document.getElementById("medicine-purpose").value.trim(),
    notes: document.getElementById("medicine-notes").value.trim(),
  };
  saveInventoryItem("medicine", item);
}

// ---------- To buy (Cupboard shopping list) ----------
// Same AppState list the iPhone reads. Web is the fallback while a
// Personal Team install is expired / being reinstalled.

function toBuyMatchKey(text) {
  return String(text || "").trim().toLowerCase();
}

const SHOP_LISTS = ["shop", "shop_medicines", "take_to_india", "bring_to_germany"];

function currentChecklistKey() {
  if (state.view === "pack") return state.packSegment;
  return state.shopSegment === "shop_medicines" ? "shop_medicines" : "shop";
}

function shopListOf(item) {
  const value = String(item?.list || "shop").trim().toLowerCase();
  return SHOP_LISTS.includes(value) ? value : "shop";
}

function itemsForShopSegment(segment = currentChecklistKey()) {
  return state.toBuy.filter((item) => shopListOf(item) === segment);
}

function sameRecipeId(a, b) {
  if (a == null || a === "") {
    return b == null || b === "";
  }
  if (b == null || b === "") return false;
  return Number(a) === Number(b);
}

function isInToBuy(text, recipeId) {
  const row = state.toBuy.find((item) => shopListOf(item) === "shop" && toBuyMatchKey(item.text) === toBuyMatchKey(text));
  if (!row) return false;
  return (row.sources || []).some((source) => sameRecipeId(source.recipe_id, recipeId));
}

function recipeSourceCount(item) {
  return (item.sources || []).filter((source) => source.recipe_id != null && source.recipe_id !== "").length;
}

function toBuyToggleHtml(text, qty, recipeId) {
  const inList = isInToBuy(text, recipeId);
  const label = inList ? t("removeFromToBuyList", { name: text }) : t("addToBuyList", { name: text });
  const icon = inList
    ? `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M5 12l5 5L19 7"/></svg>`
    : `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M12 5v14M5 12h14"/></svg>`;
  return `<button class="to-buy-toggle${inList ? " in-list" : ""}" type="button" data-action="toggle-to-buy" data-text="${escapeAttr(text)}" data-qty="${escapeAttr(qty || "")}" data-recipe-id="${escapeAttr(recipeId)}" aria-label="${escapeAttr(label)}">${icon}</button>`;
}

function renderCupboardChrome() {
  if (!els.cupboardKicker) return;
  const itemCount = state.pantryInventory.length;
  const medCount = state.medicines.length;
  const itemPart = itemCount === 1 ? t("cupboardCountOne", { n: itemCount }) : t("cupboardCountOther", { n: itemCount });
  const medPart = medCount === 1 ? t("medicinesCountOne", { n: medCount }) : t("medicinesCountOther", { n: medCount });
  els.cupboardKicker.textContent = `${itemPart} · ${medPart}`;
  const medicines = state.cupboardSegment === "medicines";
  if (els.cupboardStockSearchWrap) els.cupboardStockSearchWrap.hidden = medicines;
  if (els.cupboardMedicinesSearchWrap) els.cupboardMedicinesSearchWrap.hidden = !medicines;
  els.cupboardList.hidden = medicines;
  els.medicinesList.hidden = !medicines;
  els.cupboardSegments.querySelectorAll("[data-cupboard-segment]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.cupboardSegment === state.cupboardSegment);
  });
  if (els.cupboardAddBtn) {
    els.cupboardAddBtn.dataset.action = medicines ? "open-add-medicine" : "open-add-pantry-item";
    els.cupboardAddBtn.setAttribute("aria-label", medicines ? t("addMedicine") : t("addItem"));
  }
  els.cupboardStatus.hidden = medicines;
  if (els.medicinesStatus) els.medicinesStatus.hidden = !medicines;
}

function renderShopChrome() {
  renderChecklistChrome();
}

function renderChecklistChrome() {
  const groceryCount = itemsForShopSegment("shop").length;
  const medCount = itemsForShopSegment("shop_medicines").length;
  const indiaCount = itemsForShopSegment("take_to_india").length;
  const germanyCount = itemsForShopSegment("bring_to_germany").length;
  const groceryPart = groceryCount === 1 ? t("shopGroceriesCountOne", { n: groceryCount }) : t("shopGroceriesCountOther", { n: groceryCount });
  const medPart = medCount === 1 ? t("medicinesCountOne", { n: medCount }) : t("medicinesCountOther", { n: medCount });
  if (els.shopKicker) els.shopKicker.textContent = `${groceryPart} · ${medPart}`;
  if (els.packKicker) els.packKicker.textContent = `${indiaCount} 🇮🇳 · ${germanyCount} 🇩🇪`;
  els.shopSegments?.querySelectorAll("[data-shop-segment]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.shopSegment === state.shopSegment);
  });
  els.packSegments?.querySelectorAll("[data-pack-segment]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.packSegment === state.packSegment);
  });
  const addLabel = shopAddLabel();
  const addBtn = state.view === "pack" ? els.packAddBtn : els.shopAddBtn;
  if (addBtn) addBtn.setAttribute("aria-label", addLabel);
  const search = state.view === "pack" ? els.packSearch : els.toBuySearch;
  if (search) {
    const placeholder = shopSearchPlaceholder();
    search.placeholder = placeholder;
    const hidden = search.closest("label")?.querySelector(".visually-hidden");
    if (hidden) hidden.textContent = placeholder;
  }
}

function shopAddLabel() {
  const key = currentChecklistKey();
  if (key === "shop_medicines") return t("addMedicineToBuy");
  if (key === "take_to_india") return t("addForIndia");
  if (key === "bring_to_germany") return t("addForGermany");
  return t("addToBuy");
}

function shopSearchPlaceholder() {
  const key = currentChecklistKey();
  if (key === "shop_medicines") return t("searchShopMedicines");
  if (key === "take_to_india") return t("searchIndiaPlaceholder");
  if (key === "bring_to_germany") return t("searchGermanyPlaceholder");
  return t("searchShopGroceries");
}

function shopEmptyCopy() {
  const key = currentChecklistKey();
  if (key === "shop_medicines") return t("shopMedicinesEmpty");
  if (key === "take_to_india") return t("indiaEmpty");
  if (key === "bring_to_germany") return t("germanyEmpty");
  return t("toBuyEmpty");
}

async function loadToBuy() {
  state.toBuyLoaded = true;
  try {
    const response = await fetch("/api/to-buy", { cache: "no-store" });
    if (!response.ok) return;
    const data = await response.json();
    state.toBuy = Array.isArray(data.items) ? data.items : [];
    renderShopChrome();
    renderToBuy();
    if (state.openRecipeId != null) refreshOpenRecipe();
  } catch {
    if (els.shopStatus) els.shopStatus.textContent = t("couldNotLoad");
  }
}

async function putToBuy(items) {
  const response = await fetch("/api/to-buy", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ items }),
  });
  if (!response.ok) throw await errorForResponse(response);
  const data = await response.json();
  return Array.isArray(data.items) ? data.items : items;
}

async function postToBuySource(path, { text, qty = "", recipeId = null, category = null, notes = null }) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({
      text,
      qty,
      recipe_id: recipeId,
      category,
      notes,
    }),
  });
  if (!response.ok) throw await errorForResponse(response);
  const data = await response.json();
  return Array.isArray(data.items) ? data.items : [];
}

let toBuySyncTimer = null;

function scheduleToBuySync() {
  clearTimeout(toBuySyncTimer);
  const snapshot = state.toBuy;
  toBuySyncTimer = setTimeout(async () => {
    try {
      const confirmed = await putToBuy(snapshot);
      if (state.toBuy === snapshot) {
        state.toBuy = confirmed;
        renderShopChrome();
      }
    } catch (err) {
      window.alert(t("couldntSave", { error: err.message }));
    }
  }, 450);
}

function applyToBuyList(next, { render = true } = {}) {
  state.toBuy = next;
  renderShopChrome();
  if (render) renderToBuy();
  if (state.openRecipeId != null) refreshOpenRecipe();
}

async function replaceToBuy(next) {
  const previous = state.toBuy;
  applyToBuyList(next);
  try {
    const confirmed = await putToBuy(next);
    if (state.toBuy === next) applyToBuyList(confirmed);
  } catch (err) {
    if (state.toBuy === next) applyToBuyList(previous);
    window.alert(t("couldntSave", { error: err.message }));
  }
}

function applyingSource(items, text, qty, recipeId, category, notes, list = "shop") {
  const listKey = SHOP_LISTS.includes(list) ? list : "shop";
  const next = items.map((item) => ({ ...item, sources: [...(item.sources || [])] }));
  const index = next.findIndex((item) => shopListOf(item) === listKey && toBuyMatchKey(item.text) === toBuyMatchKey(text));
  const source = { recipe_id: recipeId == null ? null : Number(recipeId), qty: qty || "" };
  if (Number.isNaN(source.recipe_id)) source.recipe_id = null;
  if (index === -1) {
    next.push({
      id: `local-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      text,
      category: category || "Other",
      qty: qty || "",
      notes: notes || "",
      checked: false,
      sources: [source],
      list: listKey,
    });
    return next;
  }
  const row = next[index];
  row.sources = row.sources.filter((entry) => !sameRecipeId(entry.recipe_id, recipeId));
  row.sources.push(source);
  row.checked = false;
  if (notes != null) row.notes = notes;
  if (category) row.category = category;
  return next;
}

function removingSource(items, text, recipeId) {
  const next = [];
  for (const item of items) {
    if (shopListOf(item) !== "shop" || toBuyMatchKey(item.text) !== toBuyMatchKey(text)) {
      next.push(item);
      continue;
    }
    const sources = (item.sources || []).filter((entry) => !sameRecipeId(entry.recipe_id, recipeId));
    if (!sources.length) continue;
    next.push({ ...item, sources });
  }
  return next;
}

async function addToBuySource({ text, qty = "", recipeId = null, category = null, notes = null, list = "shop" }) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return;
  const listKey = SHOP_LISTS.includes(list) ? list : "shop";
  const previous = state.toBuy;
  const optimistic = applyingSource(previous, trimmed, qty, recipeId, category, notes, listKey);
  if (listKey !== "shop") {
    await replaceToBuy(optimistic);
    return;
  }
  applyToBuyList(optimistic);
  try {
    const confirmed = await postToBuySource("/api/to-buy/source", {
      text: trimmed,
      qty,
      recipeId,
      category,
      notes,
    });
    if (state.toBuy === optimistic) applyToBuyList(confirmed);
  } catch (err) {
    if (state.toBuy === optimistic) applyToBuyList(previous);
    window.alert(t("couldntSave", { error: err.message }));
  }
}

async function removeToBuySource(text, recipeId) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return;
  const previous = state.toBuy;
  const optimistic = removingSource(previous, trimmed, recipeId);
  applyToBuyList(optimistic);
  try {
    const confirmed = await postToBuySource("/api/to-buy/source/remove", {
      text: trimmed,
      recipeId,
    });
    if (state.toBuy === optimistic) applyToBuyList(confirmed);
  } catch (err) {
    if (state.toBuy === optimistic) applyToBuyList(previous);
    window.alert(t("couldntSave", { error: err.message }));
  }
}

function toggleToBuyFromRecipe(text, qty, recipeId) {
  if (isInToBuy(text, recipeId)) removeToBuySource(text, recipeId);
  else addToBuySource({ text, qty, recipeId });
}

function setToBuyQty(id, qty) {
  const index = state.toBuy.findIndex((item) => item.id === id);
  if (index === -1) return;
  const item = { ...state.toBuy[index], sources: [...(state.toBuy[index].sources || [])] };
  const sourceIndex = item.sources.findIndex((source) => source.recipe_id == null || source.recipe_id === "");
  if (sourceIndex === -1) item.sources.push({ recipe_id: null, qty });
  else {
    if (item.sources[sourceIndex].qty === qty) return;
    item.sources[sourceIndex] = { ...item.sources[sourceIndex], qty };
  }
  item.qty = qty;
  state.toBuy = state.toBuy.map((row, i) => (i === index ? item : row));
  scheduleToBuySync();
}

function setToBuyNotes(id, notes) {
  const index = state.toBuy.findIndex((item) => item.id === id);
  if (index === -1) return;
  if ((state.toBuy[index].notes || "") === notes) return;
  state.toBuy = state.toBuy.map((row, i) => (i === index ? { ...row, notes } : row));
  scheduleToBuySync();
}

function updateToBuyItem(id, { text, category, qty, notes }) {
  const index = state.toBuy.findIndex((item) => item.id === id);
  if (index === -1) return;
  const current = state.toBuy[index];
  const item = { ...current, sources: [...(current.sources || [])] };
  item.text = text;
  if (category) item.category = category;
  item.notes = notes || "";
  if (qty != null) {
    const sourceIndex = item.sources.findIndex((source) => source.recipe_id == null || source.recipe_id === "");
    if (sourceIndex === -1) item.sources.push({ recipe_id: null, qty });
    else item.sources[sourceIndex] = { ...item.sources[sourceIndex], qty };
    item.qty = qty;
  }
  state.toBuy = state.toBuy.map((row, i) => (i === index ? item : row));
  scheduleToBuySync();
  renderToBuy();
}

function shopCategoryList() {
  const order = [];
  const seen = new Set();
  const groceries = state.pantryInventoryCategories.length ? state.pantryInventoryCategories : DEFAULT_PANTRY_CATEGORIES;
  const medicines = state.medicineCategories || [];
  const key = currentChecklistKey();
  const names = key === "shop_medicines"
    ? medicines
    : key === "shop"
      ? groceries
      : [...groceries, ...medicines];
  for (const name of names) {
    const trimmed = String(name || "").trim();
    const listKey = trimmed.toLowerCase();
    if (!trimmed || seen.has(listKey)) continue;
    seen.add(listKey);
    order.push(trimmed);
  }
  return order;
}

function groupedToBuy(rows) {
  const order = [];
  const seen = new Set();
  for (const name of [...shopCategoryList(), ...rows.map((item) => item.category)]) {
    const trimmed = String(name || "").trim();
    const key = trimmed.toLowerCase();
    if (!trimmed || seen.has(key)) continue;
    seen.add(key);
    order.push(trimmed);
  }
  return order
    .map((name) => {
      const items = rows
        .filter((item) => String(item.category || "").toLowerCase() === name.toLowerCase())
        .sort((a, b) => a.text.localeCompare(b.text));
      return items.length ? [name, items] : null;
    })
    .filter(Boolean);
}

function renderToBuy() {
  const listEl = state.view === "pack" ? els.packList : els.toBuyList;
  const searchEl = state.view === "pack" ? els.packSearch : els.toBuySearch;
  if (!listEl) return;
  renderShopChrome();
  const needle = (searchEl?.value || "").trim().toLowerCase();
  const listItems = itemsForShopSegment();
  const rows = needle
    ? listItems.filter((item) =>
        item.text.toLowerCase().includes(needle)
        || (item.notes || "").toLowerCase().includes(needle)
        || (item.category || "").toLowerCase().includes(needle)
      )
    : listItems;
  if (!listItems.length) {
    listEl.innerHTML = `<div class="empty">${escapeHtml(shopEmptyCopy())}</div>`;
    return;
  }
  if (!rows.length) {
    listEl.innerHTML = `<div class="empty">${escapeHtml(t("inventoryNoMatch"))}</div>`;
    return;
  }
  if (state.view === "pack") {
    const sorted = [...rows].sort((a, b) => a.text.localeCompare(b.text));
    listEl.innerHTML = sorted.map(toBuyRowHtml).join("");
    applyViewMode();
    return;
  }
  listEl.innerHTML = groupedToBuy(rows)
    .map(
      ([category, items]) => `
    <div class="pantry-group" style="grid-column:1/-1;">
      <h3 class="pantry-heading">${escapeHtml(category)}</h3>
      <div class="grid${state.viewMode === "list" ? " view-list" : " view-grid"}">${items.map(toBuyRowHtml).join("")}</div>
    </div>`
    )
    .join("");
  applyViewMode();
}

function toBuyRowHtml(item) {
  const checked = Boolean(item.checked);
  const sources = recipeSourceCount(item);
  const checkLabel = checked ? t("uncheckItem", { name: item.text }) : t("checkItem", { name: item.text });
  const pack = shopListOf(item) === "take_to_india" || shopListOf(item) === "bring_to_germany";
  const notes = String(item.notes || "").trim();
  const qtyChip = !pack && item.qty
    ? `<span class="pill">${escapeHtml(item.qty)}</span>`
    : "";
  const recipeChip = !pack && sources > 1
    ? `<span class="inventory-meta">${escapeHtml(t("recipesCount", { n: sources }))}</span>`
    : "";
  return `
    <div class="card to-buy-card${checked ? " checked" : ""}" data-action="to-buy-card" data-id="${escapeAttr(item.id)}">
      <div class="card-actions">
        <button class="card-icon-btn" type="button" data-action="delete-to-buy" data-id="${escapeAttr(item.id)}" aria-label="${escapeAttr(t("delete"))}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13"/></svg>
        </button>
      </div>
      <div class="card-body">
        <div class="to-buy-heading">
          <button class="to-buy-check${checked ? " checked" : ""}" type="button" data-action="toggle-to-buy-checked" data-id="${escapeAttr(item.id)}" aria-label="${escapeAttr(checkLabel)}"></button>
          <h2>${escapeHtml(item.text)}</h2>
        </div>
        ${recipeChip}
        ${notes ? `<span class="inventory-meta">${escapeHtml(notes)}</span>` : ""}
        ${qtyChip ? `<div class="meta">${qtyChip}</div>` : ""}
      </div>
    </div>`;
}

function toBuyCategoryChipsHtml(selected) {
  const categories = shopCategoryList();
  const auto = selected == null || selected === "";
  const autoChip = chipButtonHtml({
    className: "chip",
    action: "pick-to-buy-category",
    dataAttr: "category",
    value: "",
    active: auto,
    label: t("categoryAuto"),
  });
  const rest = categories.map((category) =>
    chipButtonHtml({
      className: "chip",
      action: "pick-to-buy-category",
      dataAttr: "category",
      value: category,
      active: !auto && category.toLowerCase() === String(selected).toLowerCase(),
      label: category,
    })
  ).join("");
  return autoChip + rest;
}

function toBuyFormHtml(item) {
  const editing = Boolean(item);
  const title = editing ? t("edit") : shopAddLabel();
  const key = currentChecklistKey();
  const prompt = key === "shop_medicines"
    ? t("whichMedicine")
    : key === "take_to_india"
      ? t("whatToTake")
      : key === "bring_to_germany"
        ? t("whatToBring")
        : t("whatDoYouNeed");
  const pack = key === "take_to_india" || key === "bring_to_germany";
  const category = item?.category || "";
  const extraFields = pack
    ? ""
    : `
      <div class="field">
        <span>${escapeHtml(t("category"))}</span>
        <input type="hidden" id="to-buy-category" value="${escapeAttr(category)}">
        <div id="to-buy-category-chips" class="chips">${toBuyCategoryChipsHtml(category)}</div>
      </div>
      <label class="field">
        <span>${escapeHtml(t("quantity"))}</span>
        <input id="to-buy-qty-new" placeholder="${escapeAttr(t("quantityExample"))}" value="${escapeAttr(item?.qty || "")}">
      </label>`;
  return `
    <div class="drawer-actions">
      <button class="icon-btn" type="button" data-action="close-drawer">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        ${escapeHtml(t("cancel"))}
      </button>
    </div>
    <div class="recipe recipe-body">
      <h2 style="margin-bottom:1.2rem;">${escapeHtml(title)}</h2>
      <input type="hidden" id="to-buy-edit-id" value="${escapeAttr(item?.id || "")}">
      <label class="field">
        <span>${escapeHtml(t("name"))}</span>
        <input id="to-buy-text" placeholder="${escapeAttr(prompt)}" value="${escapeAttr(item?.text || "")}">
      </label>
      ${extraFields}
      <label class="field">
        <span>${escapeHtml(t("notes"))}</span>
        <textarea id="to-buy-notes-new" class="notes-grow" rows="3" placeholder="${escapeAttr(t("optional"))}">${escapeHtml(item?.notes || "")}</textarea>
      </label>
      <button class="pill-btn primary" type="button" data-action="save-to-buy">${escapeHtml(t("save"))}</button>
    </div>`;
}

function openAddToBuy() {
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  els.detail.innerHTML = toBuyFormHtml();
  els.drawer.hidden = false;
  els.detail.querySelectorAll(".notes-grow").forEach(autoGrowTextarea);
  document.getElementById("to-buy-text")?.focus();
}

function openEditToBuy(id) {
  const item = state.toBuy.find((row) => row.id === id);
  if (!item) return;
  state.openRecipeId = null;
  state.editingId = null;
  state.addingRecipe = false;
  els.detail.innerHTML = toBuyFormHtml(item);
  els.drawer.hidden = false;
  els.detail.querySelectorAll(".notes-grow").forEach(autoGrowTextarea);
}

function saveAddToBuy() {
  const text = document.getElementById("to-buy-text")?.value.trim();
  if (!text) return;
  const pack = currentChecklistKey() === "take_to_india" || currentChecklistKey() === "bring_to_germany";
  const category = pack ? null : (document.getElementById("to-buy-category")?.value || null);
  const qty = pack ? "" : (document.getElementById("to-buy-qty-new")?.value.trim() || "");
  const notes = document.getElementById("to-buy-notes-new")?.value.trim() || "";
  const editId = document.getElementById("to-buy-edit-id")?.value;
  closeDrawer();
  if (editId) {
    updateToBuyItem(editId, { text, category, qty, notes });
    return;
  }
  addToBuySource({ text, qty, category, notes, list: currentChecklistKey() });
}

function setShopSegment(segment) {
  if (segment !== "shop" && segment !== "shop_medicines") return;
  state.shopSegment = segment;
  if (els.toBuySearch) els.toBuySearch.value = "";
  renderShopChrome();
  renderToBuy();
}

function setPackSegment(segment) {
  if (segment !== "take_to_india" && segment !== "bring_to_germany") return;
  state.packSegment = segment;
  if (els.packSearch) els.packSearch.value = "";
  renderShopChrome();
  renderToBuy();
}

function setCupboardSegment(segment) {
  if (segment !== "groceries" && segment !== "medicines") return;
  state.cupboardSegment = segment;
  renderCupboardChrome();
  if (segment === "medicines") renderInventory("medicine");
  else renderInventory("cupboard");
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
  state.sourceFilters = new Set();
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

els.viewTabs.addEventListener("click", (event) => {
  const btn = event.target.closest("[data-view]");
  if (!btn) return;
  switchView(btn.dataset.view);
});

els.cupboardSearch.addEventListener("input", () => renderInventory("cupboard"));
els.toBuySearch?.addEventListener("input", () => renderToBuy());
els.packSearch?.addEventListener("input", () => renderToBuy());
els.medicinesSearch.addEventListener("input", () => renderInventory("medicine"));
els.cupboardSegments?.addEventListener("click", (event) => {
  const btn = event.target.closest("[data-cupboard-segment]");
  if (!btn) return;
  setCupboardSegment(btn.dataset.cupboardSegment);
});
els.shopSegments?.addEventListener("click", (event) => {
  const btn = event.target.closest("[data-shop-segment]");
  if (!btn) return;
  setShopSegment(btn.dataset.shopSegment);
});
els.packSegments?.addEventListener("click", (event) => {
  const btn = event.target.closest("[data-pack-segment]");
  if (!btn) return;
  setPackSegment(btn.dataset.packSegment);
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
els.cameraInput?.addEventListener("change", handlePhotoSelected);

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
    case "toggle-view-mode":
      toggleViewMode();
      break;
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
    case "log-filter":
      state.logFilter = actionEl.dataset.filter || "all";
      state.logShown = LOG_PAGE_SIZE;
      renderSettings();
      break;
    case "log-more":
      state.logShown = (Number(state.logShown) || LOG_PAGE_SIZE) + LOG_PAGE_SIZE;
      renderSettings();
      break;
    case "toggle-log-details": {
      const key = actionEl.dataset.key;
      if (state.revealedLogKeys.has(key)) state.revealedLogKeys.delete(key);
      else state.revealedLogKeys.add(key);
      renderSettings();
      break;
    }
    case "copy-log-url": {
      const url = actionEl.dataset.url || "";
      const key = actionEl.dataset.key;
      navigator.clipboard.writeText(url).then(() => {
        state.copiedLogKey = key;
        if (isSettingsOpen()) renderSettings();
        window.setTimeout(() => {
          if (state.copiedLogKey !== key) return;
          state.copiedLogKey = null;
          if (isSettingsOpen()) renderSettings();
        }, 1600);
      }).catch(() => {});
      break;
    }
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
    case "toggle-source-filter": {
      const source = actionEl.dataset.source;
      if (state.sourceFilters.has(source)) state.sourceFilters.delete(source);
      else state.sourceFilters.add(source);
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
    case "open-add-camera":
      els.addRecipeMenu.hidden = true;
      if (els.cameraInput) {
        els.cameraInput.value = "";
        els.cameraInput.click();
      } else {
        els.photoInput.value = "";
        els.photoInput.click();
      }
      break;
    case "open-add-pantry-item":
      openAddInventoryItem("cupboard");
      break;
    case "open-add-to-buy":
      openAddToBuy();
      break;
    case "pick-to-buy-category": {
      const input = document.getElementById("to-buy-category");
      const chips = document.getElementById("to-buy-category-chips");
      if (input) input.value = actionEl.dataset.category || "";
      if (chips) chips.innerHTML = toBuyCategoryChipsHtml(input?.value || "");
      break;
    }
    case "save-to-buy":
      saveAddToBuy();
      break;
    case "toggle-to-buy":
      event.stopPropagation();
      toggleToBuyFromRecipe(actionEl.dataset.text, actionEl.dataset.qty || "", actionEl.dataset.recipeId);
      break;
    case "toggle-to-buy-checked": {
      const id = actionEl.dataset.id;
      const next = state.toBuy.map((item) => (item.id === id ? { ...item, checked: !item.checked } : item));
      replaceToBuy(next);
      break;
    }
    case "to-buy-card":
      openEditToBuy(actionEl.dataset.id);
      break;
    case "delete-to-buy":
      event.stopPropagation();
      replaceToBuy(state.toBuy.filter((item) => item.id !== actionEl.dataset.id));
      break;
    case "open-add-medicine":
      openAddInventoryItem("medicine");
      break;
    case "edit-inventory-item":
      openEditInventoryItem(actionEl.dataset.kind, actionEl.dataset.id);
      break;
    case "delete-inventory-item":
      event.stopPropagation();
      deleteInventoryItem(actionEl.dataset.kind, actionEl.dataset.id);
      break;
    case "save-pantry-item":
      saveAddOrEditPantryItem();
      break;
    case "save-medicine":
      saveAddOrEditMedicine();
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
applyViewMode();
loadCachedRecipes();
load().catch(() => {
  if (!state.recipes.length) {
    els.status.textContent = t("couldNotLoad");
  } else {
    setOfflineBanner(true);
  }
});
