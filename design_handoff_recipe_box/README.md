# Handoff: Stocked (formerly Recipe Box) iOS redesign

## Overview
A warm visual redesign of the personal Recipe Box iPhone app (`ios/RecipeBox/`, SwiftUI), renamed **Stocked**,
plus a paste-a-link add flow, a course filter (Main course / Appetizers / Desserts), and a new second tab —
a personal pantry inventory called **Cupboard**, alongside the recipes tab now called **Cookbook**. Backend is
unchanged except where noted under "API / data".

## About the design files
`Recipe Box.dc.html` and `AppIcon.dc.html` in this bundle are **design references written in HTML** — an
interactive prototype of the intended look and behavior. They are not production code. The task is to recreate
them in the existing SwiftUI app, following its established patterns (`Theme.swift`, `RecipeStore`, `APIClient`).

Open `Recipe Box.dc.html` in a browser: the left rail jumps between screens, and the phone is fully tappable.

## Fidelity
**High-fidelity.** Final colors, typography, spacing and interactions. Recreate pixel-for-pixel using SwiftUI
primitives; every value below is exact.

## Design tokens — replace Theme.swift wholesale
The old sage/grey palette is retired. New palette (from the Organic design system):

| Token | Hex | SwiftUI |
| --- | --- | --- |
| bg (page ground) | #f5ead8 | Color(red: 0.961, green: 0.918, blue: 0.847) |
| surface (cards, fields) | #ebddc5 | Color(red: 0.922, green: 0.867, blue: 0.771) |
| text (ink) | #201e1d | Color(red: 0.125, green: 0.118, blue: 0.114) |
| accent (terracotta) | #c67139 | Color(red: 0.776, green: 0.443, blue: 0.224) |
| accent-600 (pressed) | #b2622d | Color(red: 0.698, green: 0.384, blue: 0.176) |
| accent-700 (accent text) | #8c491a | Color(red: 0.549, green: 0.286, blue: 0.102) |
| accent-800 (text on tint) | #643312 | Color(red: 0.392, green: 0.200, blue: 0.071) |
| accent-900 (cook mode bg) | #402310 | Color(red: 0.251, green: 0.137, blue: 0.063) |
| accent-100 / 200 / 300 (tints) | #fff2eb / #ffe1d0 / #ffc6a5 | — |
| accent-2 sage 500 / 300 / 100 | #8fa073 / #ccdbb2 / #f0fae1 | — |
| accent-2-800 (sage text) | #3d472b | — |
| neutral 200 / 300 / 400 / 600 / 700 / 800 / 900 | #eee7db / #dcd3c4 / #c0b6a5 / #82796a / #645c50 / #474238 / #2e2b25 | — |
| divider | #201e1d at 16% opacity | — |

Type: **Caprasimo** (regular 400) for all headings, titles and button labels — bundle the TTF from Google Fonts
and register it in Info.plist (`UIAppFonts`). **Figtree** (400/600/700) for body, labels and inputs. This
replaces the previous `design: .serif` / `.monospaced` system-font stand-ins in Theme.swift.

Radii: containers 28–32pt; cards 30pt; every button, chip, pill and text field is fully rounded (Capsule()).
Shadows: sm `0 1 2 rgba(46,43,37,0.14)`, md `0 3 10 rgba(46,43,37,0.16)`.
Spacing: 22pt screen side padding throughout; 13pt between list cards; 18–26pt between detail sections.

## Screens

### 1. Recipe list (RecipeListView + RootView toolbar)
Replace the `List(.insetGrouped)` with a `ScrollView` of cards on the bg color. The nav bar title is gone; the
header is inline content.

- **Header**, 66pt top padding, 22pt sides. Decorative accent-200 circle, 210pt, positioned top -70 / right -60,
  clipped by the screen. Kicker (Figtree 10.5pt, uppercase, tracking 0.14em, accent-700): "6 RECIPES · 1 FAVORITE".
  Title "Stocked" — Caprasimo 36pt, ink.
- **Header buttons**, top-right, 42×42 circles, 8pt apart: settings (gear, sage-neutral icon, surface fill,
  1pt divider border) and add (plus, cream glyph on accent fill, shadow-sm). Lucide icons, stroke width 2.75.
- **Search row**, 18pt below the title: pill 46pt tall, surface fill, 1pt divider border, 16pt inner padding,
  search icon then text field, placeholder "Search recipes" (Figtree 14.5pt). To its right a
  46×46 pill filter button; when any filter is active it fills accent with a cream icon.
- **Pantry suggestion row** (unchanged behavior from the current app): appears under search when the query
  matches a pantry ingredient. Label "MARK AS SOMETHING YOU HAVE" (10pt uppercase, neutral-600) over dashed
  sage chips reading "+ paneer" (sage-100 fill, sage-400 dashed border, sage-800 text, 12.5pt).
- **Course filter row — NEW**, directly below the search block, 3 equal-width pill buttons with 7pt gaps:
  "Main course", "Appetizers", "Desserts". Unselected: surface fill, divider border, neutral-800 text.
  Selected: accent fill, cream text. Tapping the selected one clears it. Composes with all other filters.
- **"What I have" banner**: when the pantry is non-empty, a sage-100 pill above the list: 8pt sage dot,
  "Sorted by fit to paneer, butter" (12.5pt sage-800), and a "Clear" text button on the right.
- **Grid/list toggle — NEW**: a third 46×46 circular button beside the filter button, surface fill, divider
  border, showing a grid or list glyph for the *other* mode (list glyph while in grid view, grid glyph while
  in list view). Persists as a `viewMode` state, defaulting to list.
- **Recipe card, list mode**: surface fill, 30pt radius, shadow-sm, padding 18/20/17. Contents top to bottom,
  10pt apart:
  1. Meta row — source label (10pt uppercase, tracking 0.12em, neutral-600, e.g. "INSTAGRAM"); optional
     "72% FIT" pill (sage-500 fill, cream text) when the pantry is active; spacer; favorite star (18pt, accent
     filled when on, neutral-400 outline when off). Tapping the star must not open the recipe.
  2. Title — Caprasimo 21pt, line height 1.15, up to 2 lines.
  **No time, no servings, no tags anywhere on the card** (deliberately removed).
- **Recipe card, grid mode — NEW**: a 2-column grid, same 13pt gap as the list's card spacing. Cards drop the
  source label (fit pill and favorite star stay), tighten to 22pt radius / 15,16,14pt padding / 8pt internal
  gap, and shrink the title to Caprasimo 16pt. Same tap target and favorite behavior as list mode.
- Cards fade+rise in (opacity 0→1, translateY 6→0, 0.3s ease), in either layout.
- **Add sheet**: tapping + presents a bottom sheet (bg fill, 34pt top corners, 26/22/40 padding) over a 42%
  neutral-900 scrim, with a 44×5 grab handle, heading "Add a recipe" (Caprasimo 24pt) and four rows
  (surface fill, 24pt radius, 15/18 padding, 38pt accent-200 circle glyph, Caprasimo 16pt label, 12.5pt
  neutral-700 sub): "Paste a link / Reel, video, or recipe page", "Take a photo / Cookbook page or recipe card",
  "Choose from library / A screenshot you already saved", "Type it in / Write it down yourself".

### 2. Recipe detail (RecipeDetailView)
- Toolbar: 40pt circular back, favorite (accent when on) and ellipsis buttons, surface fill, divider border.
- **Ellipsis menu — NEW**: tapping it opens a dropdown anchored top-right, surface fill, 20pt radius,
  shadow-lg, 6pt padding, below a fixed 46pt gap. Rows: "Original post" (external-link glyph, only when the
  recipe has a source link — Instagram/YouTube/TikTok/Link), "Edit recipe" (pencil glyph), a 1pt divider, then
  "Delete recipe" (trash glyph, accent-800 text). Each row: 11pt icon-to-label gap, 11/12 padding, 14pt radius,
  accent-100 hover. A full-screen transparent tap-catcher behind the menu closes it on outside tap.
- **Delete confirm — NEW**: a centered dialog over a 42% neutral-900 scrim — "Delete this recipe?" (Caprasimo
  20pt) / "This removes it from your box. This can't be undone." (14pt neutral-700), then Cancel (surface,
  divider border, bold 14.5pt) and Delete (accent-800 fill, cream text, bold 14.5pt, shadow-sm, darkens on
  hover) side by side. Confirming removes the recipe and returns to the list.
- **Edit sheet — NEW**: "Edit recipe" opens a bottom sheet (same shell as the pantry add sheet) prefilled from
  the current recipe, covering Title (pill field), Course (chip row), **Tags** (see tag-creation pattern below),
  Ingredients (textarea, one per line as "qty | item", blank qty allowed), Steps (textarea, blank line between
  steps), and Notes (textarea). No time or servings fields — this app doesn't track either. Saving parses the
  textareas back into the ingredient/step arrays and updates the recipe in place.

**Tag creation pattern — NEW, used identically in Edit recipe, From a photo, and Type it in:** a wrapping row
of existing-tag chips (capsule, 12.5pt, 7/14 padding; selected accent/cream, unselected surface/neutral-800
with a divider border — tap to toggle) followed by a "New tag" text field (42pt pill) plus an "Add tag"
button (accent-100 fill, accent-800 text, 42pt pill). Add tag trims the input, adds it case-insensitively to
the app's global tag list if new, selects it for the current recipe, and clears the field. Tags are created
only from these three add/edit surfaces — **Filters only ever lets the user filter by tags that already
exist**; it has no add-tag control. A recipe saved by pasting a link is tagged automatically by the import
model same as before; the user adds their own tags afterward via Edit recipe.
- **Hero card**: surface fill, 32pt radius, 24/22 padding, with an accent-200 circle 170pt at right -46 /
  bottom -58, clipped. Kicker "SAVED 2 DAYS AGO" (10.5pt uppercase, accent-700). Title Caprasimo 31pt, max
  ~16 characters per line. Below it, 14pt down, the **course pill — NEW**: accent fill, cream text, 11.5pt,
  5/13 padding, reading "Main course" / "Appetizers" / "Desserts".
- **Pantry line** (when active): sage-100 pill, 22pt radius, 13pt sage-800 text — "You have everything for
  this." or "Missing 3: chili crisp, black vinegar, spring onions".
- **Start cooking**: full-width accent pill, 16pt padding, Caprasimo 16pt cream label, play glyph, shadow-sm.
- **Ingredients**: heading Caprasimo 23pt with the scale control on the same baseline — ½× / 1× / 2× / 3×
  pills, 12pt; the selected one is accent/cream, others surface/neutral-700. Quantity chips are accent-200
  with accent-800 text at 1×, and accent with cream text at any other scale (so a scaled list is visibly
  scaled). Rows: surface card, 28pt radius, 13pt vertical padding per row, 1pt divider between rows, quantity
  chip (min width 62pt, centered) then ingredient text (14.5pt). Quantity-less lines render as plain text.
  **No servings/time line.** Multi-component recipes may show section headers within this list — see
  "Ingredient sections" below.
- **Steps**: heading Caprasimo 23pt; rows 16pt apart — 28pt accent-200 circle with the number in
  Caprasimo 13pt accent-800, then the step text at 14.5pt / line height 1.55.
- **Notes**: accent-100 card, 26pt radius, "NOTES" kicker, 14pt body.
- **End of page, in this order**: tag pills (11.5pt, accent-100/accent-800) then a single quiet line
  "From Instagram" (12pt neutral-600, the source name being the link to the original post). The source is
  deliberately the least prominent thing on the screen.

### 3. Cook mode (CookModeView)
- Ground accent-900 (#402310), foreground #f7ecd9, with an accent circle at 18% opacity, 260pt, top -90 /
  left -70. This is the only dark screen in the app.
- Header: 40pt circular close (foreground at 14% fill) on the left, recipe title centered (12pt uppercase,
  tracking 0.1em, 65% opacity), and the 40pt circular **back-step** button on the right (40% opacity on step 1).
- Center: "STEP 2 OF 5" (12pt, tracking 0.2em, accent-400) then the step text in Caprasimo 32pt, centered,
  line height 1.2, cross-fading on change (0.25s).
- Bottom: progress ticks — one 5pt capsule per step, 6pt apart, accent when at or before the current step,
  foreground at 18% after. Then **one full-width primary button, 62pt tall, in a fixed position**, reading
  "Next step" and then "Done cooking" on the last step. Keeping the primary in one fixed slot for the whole
  session is the point of the change — nothing else may sit beside it.
- **Long-step responsiveness — NEW.** The step text sits in a `flex:1` area between the header and the
  ticks/button, which is otherwise fixed height, so a long step can't just grow the layout. Two mechanisms,
  applied in order:
  1. **Type scales down by character count**: 32pt (≤70 chars) → 27pt (≤120) → 23pt (≤190) → 20pt (above
     190). Short steps stay at full size; only long ones shrink.
  2. **Scroll fallback past ~300 characters**: the step text becomes vertically scrollable within its area
     (scrollbar hidden) with a bottom fade mask that clears once the user has scrolled to the end, signalling
     there's more below. Scroll position and the "reached end" state reset whenever the step changes (Next/Back).
  In SwiftUI: a `GeometryReader`-sized or fixed-height container with a `ScrollView` for the step text, a
  step-length-driven font size, and a `.mask(LinearGradient(...))` bottom fade shown only while scrolled
  content remains below the fold.
- Keeps `isIdleTimerDisabled = true` and the existing swipe gestures.

### 4. Paste a link — NEW screen
Reached from the add sheet. Cancel button top-left.
- Title "Paste a link" Caprasimo 30pt; body "A reel, a video, or any recipe page. We read it and fill the card
  in for you." (14pt neutral-700).
- Row: URL field (50pt pill, surface, placeholder "https://…") plus a "Paste" button that reads the clipboard.
- **Detected state**: accent-100 pill with an accent dot and a source-specific line —
  Instagram: "Instagram reel — caption and owner comment will be read";
  YouTube/TikTok: "Video — audio and description will be read"; anything else: "Page — the text will be read".
- **Fetching state**: surface card, 28pt radius, three rows with 22pt ring spinners — "Fetching the post",
  "Reading the recipe", "Saving to your box". The active row spins in accent; completed rings are sage-500;
  pending rings are neutral-200 with neutral-600 text.
- **Done state**: sage-100 card — "SAVED TO YOUR BOX" kicker, the extracted title in Caprasimo 21pt, and
  "7 ingredients · 5 steps · 15 min" in 13pt sage-800.
- Primary button label follows the phase: "Save recipe" → "Reading…" (disabled) → "Open the recipe", which
  navigates to the new recipe's detail screen.
- Footnote: "Sharing from the app's share sheet still works exactly as before — this is for when the link is
  already on your clipboard."
- **API / data**: POST the URL to the existing `/ingest` endpoint with the `X-Recipe-Box-Key` header, exactly
  as the Shortcut does, then refresh the store. Mind the 60s Vercel ceiling — show the fetching state for the
  whole wait and surface `status: "error"` payloads inline under the field rather than in an alert.

### 5. From a photo (AddRecipeView with a prefill)
Cancel / Save in the header. Title "From a photo" (Caprasimo 30pt) and the line "Check what we read off the page
before it goes in the box." **The photo itself is not shown or stored** — go straight to the read-back: a sage-100
confidence pill ("Read 9 ingredients and 6 steps. Confidence: high."), then Title (pill field, Caprasimo 17pt),
Ingredients (26pt-radius surface field, one per line, line height 1.9), **Steps — NEW** (same 26pt-radius surface
card, numbered rows: 22pt accent-200 circle with the step number in 12pt accent-800, then the step text at 14pt;
this block was missing even though the confidence pill already claimed a step count), the Course pill row, **Tags**
(the tag-creation pattern described under screen 2's edit sheet — existing chips plus New tag / Add tag), and the
line "Source is set automatically — this one files under **Photo** in Filters."

### 6. Type it in (AddRecipeView)
Cancel / Save header, title "Type it in". Fields, 18pt apart, all labelled with 10.5pt uppercase neutral-600
kickers: Title (50pt pill), Ingredients (textarea 120pt, hint "one per line"), Steps (textarea 130pt, hint "one
per line, in order"), Course (three equal pills: Main course / Appetizers / Desserts) and **Tags** (the same
tag-creation pattern — existing chips plus New tag field / Add tag button), then the line
"Source is set automatically — this one files under **Typed in** in Filters."
**Servings, Time and the Meal chip row are all removed** — the model keeps those fields, the form no longer
asks for them. Course and Tags are the only classifications either add form collects, so that anything created
in the app is reachable from every filter on the list screen.

### 7. Filters (FiltersSheet)
Reset / Done header, title "Filters" (Caprasimo 30pt), then in order:
- **What I have** — sage-100 card, 30pt radius: marked ingredients as sage-500 chips with a "×", or "Nothing
  marked yet.", plus the line "Sorts recipes by closest fit. Type an ingredient in search to add one."
- **Source — NEW** chip row: Instagram, YouTube, TikTok, Link, Photo, Typed in. Multi-select, matched against
  the recipe's source column; composes with the other filters and is cleared by Reset.
- **Tags** chip row: mom's recipes, veg, non-veg, dessert, high protein, airfryer, plus any tag the user has
  since created from Edit recipe / From a photo / Type it in. Select-only — Filters has no way to create a tag.
- **Favorites only** — full-width surface row, 26pt radius, star glyph; accent text when on.
- **Sort** — three equal pills: Recent, A–Z, Z–A (ignored while the pantry is active, as today).
Chip style everywhere: 12.5pt, 7/14 padding, capsule; selected accent/cream, unselected surface/neutral-800
with a divider border.

### 8. Settings (SettingsView)
Close button; title "Settings". Reordered so the settings a normal user cares about are visible by default, and
the ones only useful for debugging are tucked away:
- **Language** chip row, first on the page: System, English, Deutsch. Selecting one applies immediately —
  no save step, no "reload" — since it's a live app preference, not a value round-tripping to the server.
- Divider, then **Import limits** as its own labeled section (no card/background — plain label + two 6pt
  progress bars on neutral-200 tracks, accent fill), separate from Language rather than nested under it:
  "Imports today — 6 of 20" (a count) and "Import cost this month — $1.20 of $5" (a dollar figure; keep it
  as cost, not a count — these are two different kinds of limit). User-facing because the user needs to know
  how many recipe imports they have left before hitting the daily/monthly cap; the labels intentionally say
  nothing about which backend/model serves the import.
- **"Developer" disclosure row** below that: an uppercase label with a chevron that rotates 180° when open,
  collapsed by default. Expanding it reveals: Server field (pill, showing the hosted URL) with its
  explanatory footnote; Edit key field (masked, 0.22em tracking) with its footnote; and a "Save and reload"
  primary button, scoped only to those two fields (Import limits is display-only and sits outside this
  section; Language applies instantly and also sits outside it).
The quota numbers backing Import limits need a small backend addition; if that is not wanted, drop the card
rather than faking it, but keep it visible (not inside Developer) once real — recipe-import cadence is
something end users plan around.

### 9. Empty state
Two soft circles (accent-200 top-right, sage-200 bottom-left, 240/200pt, 60% opacity), a 78pt accent circle with
a cream plus glyph, "Add your first recipe" (Caprasimo 34pt), "Share a reel from Instagram, paste a link, snap a
cookbook page, or write one down yourself." and a left-aligned "Get started" accent pill. Left-aligned,
not centered.

### 10. Loading state
Header title, then a spinner plus "Loading your recipes…" (13pt neutral-700) — the label matters, skeletons
alone were ambiguous — then four skeleton cards (surface, 30pt radius, three neutral-200/300 bars at
34% / 55–84% / 52% width) pulsing between 45% and 85% opacity on a 1.4s loop.

## Interactions & behavior
- List filtering is the intersection of: search text (title, tags, ingredient text), course, sources, tags,
  favorites-only. Sort applies unless the pantry is non-empty, in which case fit descending always wins.
- Fit % = matched pantry items / total pantry items for that recipe, rounded.
- Favorite toggles optimistically and PATCHes as today; the star on a card must not trigger navigation.
- Ingredient scaling multiplies the leading number of a quantity and rounds to 2 decimals.
- Every interactive element needs a hover/pressed state one ramp step past its base (accent → accent-600 on
  light grounds, accent → accent-400 on the dark cook screen), and a 2pt accent focus ring for keyboard/VoiceOver.

### 11. Cupboard — NEW tab
Reached via a bottom tab bar now present on both screens: **Cookbook** (an open-book glyph, the renamed recipe
list/detail/cook flow) and **Cupboard** (a two-door cabinet glyph, the new pantry tab), accent when active,
neutral-500 otherwise. This is the user's own inventory — it is not required to be in sync with any recipe.
- **Header**: same style as the recipe list — Caprasimo 36pt "Cupboard", kicker line "12 items · 2 to buy".
  Below it a 2-segment control (Items / To buy) — same chip styling as filter chips.
- **Search bar — NEW**: above the Items list, a pill search field identical in style to the Cookbook search
  ("Search what's in stock"), filtering the grouped list by item name or category. The To buy tab has its own
  matching search field ("Search items to buy") filtering the checklist by item text. Independent queries —
  switching sub-tabs does not clear the other's search.
- **Items tab**: a "Select items to match" toggle pill (full width minus a 44×44 add-item circle button) —
  entering match mode shows a checkbox circle on the left of every row instead of the trash icon.
  Items are **grouped by category** (Produce, Dairy & eggs, Meat & seafood, Grains & pantry, Condiments &
  spices, Other) under 10.5pt uppercase kickers. Each row: surface card, 22pt radius, shadow-sm — name (14.5pt
  semibold) with a chip line below it: amount+unit (neutral-100 pill), Open/Unopened status (sage or neutral
  tint), and an **expiry badge** when set — neutral outline showing the date normally, a sage-200/800 tint for
  "Expires in Nd" between 4-7 days out, a solid accent-500 fill ("Expires in 2d" / "Expires today") inside
  3 days, and accent-800 ("Expired") once past.
  Tapping a row (outside match mode) opens it in the same add/edit sheet, prefilled, for editing; a trash
  icon on the row deletes it directly.
  **No photos or avatar icons on rows** — deliberately left out.
- **Add/edit item sheet**: bottom sheet, same shell as the recipe edit sheet. Fields: Name (pill field),
  Category (chip row), Amount + Unit (number field beside a 3-way pcs/g/kg chip row), Status (Unopened/Open
  2-pill row), Expiry date (native date input, optional), Notes (textarea, optional). Title and button label
  switch to "Edit pantry item" / "Save changes" when opened from an existing row, vs. "Add pantry item" /
  "Add to pantry" for a new one.
- **Match mode**: selecting items surfaces a sage-100 result card above the grouped list — "N selected ·
  matching recipes" — listing up to 4 recipes ranked by how many selected items they use, each row showing the
  recipe title and "2 of 6 ingredients". Matching does not require every pantry item to be used; it's a partial,
  best-effort match on ingredient word stems (handles plurals), independent of the list screen's pantry "fit %".
  Tapping a result opens that recipe.
- **To buy tab**: the search bar above, then a text field + add button row, then a plain checklist — each row a circle checkbox (sage-500
  when checked), the item text (strikethrough + muted when checked), a **quantity field — NEW** (64pt pill,
  bg fill, divider border, 12.5pt centered text, placeholder "qty", freely editable), and a trash icon per row.
  Manually populated; no auto-sync to pantry stock levels. Items added from a recipe (below) prefill this field
  with that ingredient's quantity string (e.g. "200 g"); manually typed items start blank.
- **Add to buy from a recipe — NEW**: every ingredient row on the recipe detail screen has a small round
  button (plus glyph, neutral-100 fill) that adds that ingredient's text to the pantry's To-buy list; it fills
  sage with a checkmark once added, and tapping again removes it. This is the only link between recipes and
  the pantry's to-buy list — everything else in Pantry is independent of recipes.

### Steps numbering — fixed
The numbered circle before each step (recipe detail and the photo-review screen) previously set the digit in
Caprasimo, whose baseline sits low and off-center inside a circle at small sizes. Digits now render in the body
font, bold, line-height 1, which centers correctly; the circle gets a 1-2pt top margin so it lines up with the
first line of the step text instead of the vertical center of the whole (often 2-line) row.

## State
`screen`, `query`, `have: [String]`, `favs: [Int: Bool]`, `tags: Set<String>`, `sources: Set<String>`,
`course: String?`, `favOnly: Bool`, `sort`, `currentId`, `step`, `scale`, `addSheet: Bool`,
`link`, `linkPhase: idle|fetching|done`. `course` and `sources` are new; everything else exists in RecipeStore.

Per-form tag selection is separate state from the Filters `tags` set — `formTags` (Type it in / From a photo)
and `editTagsList` (Edit recipe) each hold their own selected-tags array so picking tags on a recipe never
touches the Filters selection. The app's global tag list (`ALL_TAGS`) grows whenever "Add tag" is used from
any of the three add/edit surfaces.

`language: String` ("System" | "English" | "Deutsch") and the Server/Edit key fields are Settings-only state;
Import limits values come from the backend, not local state.

`pantry: [PantryItem]` (id, name, category, amount, unit, status: open|unopened, expiry: Date?, notes) and
`toBuy: [{id, text, checked}]` are new, independent top-level stores — no foreign key to `RecipeStore`.

## Ingredient sections — NEW
A recipe's ingredients can optionally be split into labeled parts (e.g. "For the sauce", "For the chicken",
"For the rice") for multi-component recipes. On the detail screen, each section renders as a small header row
above its items: the label in Figtree 12pt, 700 weight, uppercase, 0.06em letter-spacing, accent-2-800 —
20pt top padding to separate it from the previous group (2pt for the first section in the list), 9pt below
before the first item. Sections are purely presentational grouping; scaling, buy-list add, and pantry-fit matching all
operate on the underlying flat ingredient list and skip section headers.
In the Edit recipe textarea, a section header is written as its own line starting with `## ` (e.g.
`## For the sauce`), interleaved with the normal `qty | item` lines beneath it. Recipes with no `##` lines
behave exactly as before — this is fully backward compatible with flat ingredient lists.
Data model: each ingredient entry is a 2-tuple `[qty, text]` as before; a section header reuses the same shape
with `qty` set to the sentinel `'@section'` and `text` holding the label. Demonstrated live on the "Lemon
Tahini Salmon Bowl" recipe (For the salmon / For the tahini sauce / For the bowl).

## Logs — NEW
Settings now has a Logs section (below Developer): All/Saved/Errors filter chips (same pill-chip pattern as
elsewhere), then a list of import log entries. Each entry: a check (accent-2-600) or X (accent-700) icon +
timestamp, title in Caprasimo 16pt, and an "Additional details" toggle (chevron rotates on open) revealing
the model name and source link — shown for both successful and failed imports. Paginated 5 at a time with a
"Show more" button (pill, outline) that appends 5 more; switching filters resets the count to 5. The
Language setting was removed (app is English-only).

## Data model change
Add a **course** value per recipe — "Main course", "Appetizers" or "Desserts" — shown as the pill on the detail
screen and driven by the new top filter row. Options: derive it from the existing `meal` column
(dessert → Desserts, snack → Appetizers, everything else → Main course), or add a Course column to the sheet and
have Gemini fill it. Derivation needs no backend change and is the recommended first step.

### Back button ring — fixed
The recipe detail back button's ring now uses an inset `box-shadow` (1px, divider color; 1.5px accent on hover)
instead of a `border` — a uniform stroke at any render scale, where the border could appear uneven.

## Assets
- `AppIcon-1024.png` — the app icon, square 1024×1024, no transparency, no pre-rounded corners. Drop it on the
  1024 slot of the AppIcon set in `ios/RecipeBox/Assets.xcassets`. Icon artwork is a stylized cooking pot with
  sprouts, unrelated to the cupboard/cookbook tab icons used inside the app — kept intentionally simple as a
  1024px mark rather than illustrating the two-tab structure.
- `AppIcon.dc.html` — the icon's source, parametric by size, if any other size is needed.
- Icons: Lucide (https://lucide.dev) at stroke width 2.75, or the closest SF Symbol at `.semibold`.
- Fonts: Caprasimo and Figtree, both from Google Fonts, both OFL.
- No photographs are used anywhere in this design.

## Files in this bundle
- `Recipe Box.dc.html` — the full interactive prototype (all ten screens).
- `AppIcon.dc.html` — the app icon at any size.
- `AppIcon-1024.png` — the exported icon.
- `ios-frame.jsx`, `support.js`, `_ds/` — supporting files the prototype needs in order to open in a browser.
