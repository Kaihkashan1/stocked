# Handoff: Recipe Box iOS redesign

## Overview
A warm visual redesign of the personal Recipe Box iPhone app (`ios/RecipeBox/`, SwiftUI), plus two functional
additions: a paste-a-link add flow and a course filter (Main course / Appetizers / Desserts). Backend is unchanged
except where noted under "API / data".

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
  Title "Recipe Box" — Caprasimo 36pt, ink.
- **Header buttons**, top-right, 42×42 circles, 8pt apart: settings (gear, sage-neutral icon, surface fill,
  1pt divider border) and add (plus, cream glyph on accent fill, shadow-sm). Lucide icons, stroke width 2.75.
- **Search row**, 18pt below the title: pill 46pt tall, surface fill, 1pt divider border, 16pt inner padding,
  search icon then text field, placeholder "Search, or type what you have…" (Figtree 14.5pt). To its right a
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
  **No servings/time line.**
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
Ingredients (26pt-radius surface field, one per line, line height 1.9), the Course pill row, the Tags chip row,
and the line "Source is set automatically — this one files under **Photo** in Filters."

### 6. Type it in (AddRecipeView)
Cancel / Save header, title "Type it in". Fields, 18pt apart, all labelled with 10.5pt uppercase neutral-600
kickers: Title (50pt pill), Ingredients (textarea 120pt, hint "one per line"), Steps (textarea 130pt, hint "one
per line, in order"), Course (three equal pills: Main course / Appetizers / Desserts) and Tags (chip row), then the line
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
- **Tags** chip row: mom's recipes, veg, non-veg, dessert, high protein, airfryer (the existing fixed set).
- **Favorites only** — full-width surface row, 26pt radius, star glyph; accent text when on.
- **Sort** — three equal pills: Recent, A–Z, Z–A (ignored while the pantry is active, as today).
Chip style everywhere: 12.5pt, 7/14 padding, capsule; selected accent/cream, unselected surface/neutral-800
with a divider border.

### 8. Settings (SettingsView)
Close button; title "Settings". Server field (pill, showing the hosted URL) with the existing explanatory
footnote; Edit key field (masked, 0.22em tracking) with its footnote; **new "API usage" card** (surface, 28pt
radius) with two 6pt progress bars on neutral-200 tracks, accent fill: "Gemini reads today — 6 of 20" and
"Instagram credit — $1.20 of $5". Primary "Save and reload" button. The quota numbers need a small
backend addition; if that is not wanted, drop this card rather than faking it.

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

## State
`screen`, `query`, `have: [String]`, `favs: [Int: Bool]`, `tags: Set<String>`, `sources: Set<String>`,
`course: String?`, `favOnly: Bool`, `sort`, `currentId`, `step`, `scale`, `addSheet: Bool`,
`link`, `linkPhase: idle|fetching|done`. `course` and `sources` are new; everything else exists in RecipeStore.

## Data model change
Add a **course** value per recipe — "Main course", "Appetizers" or "Desserts" — shown as the pill on the detail
screen and driven by the new top filter row. Options: derive it from the existing `meal` column
(dessert → Desserts, snack → Appetizers, everything else → Main course), or add a Course column to the sheet and
have Gemini fill it. Derivation needs no backend change and is the recommended first step.

## Assets
- `AppIcon-1024.png` — the app icon, square 1024×1024, no transparency, no pre-rounded corners. Drop it on the
  1024 slot of the AppIcon set in `ios/RecipeBox/Assets.xcassets`.
- `AppIcon.dc.html` — the icon's source, parametric by size, if any other size is needed.
- Icons: Lucide (https://lucide.dev) at stroke width 2.75, or the closest SF Symbol at `.semibold`.
- Fonts: Caprasimo and Figtree, both from Google Fonts, both OFL.
- No photographs are used anywhere in this design.

## Files in this bundle
- `Recipe Box.dc.html` — the full interactive prototype (all ten screens).
- `AppIcon.dc.html` — the app icon at any size.
- `AppIcon-1024.png` — the exported icon.
- `ios-frame.jsx`, `support.js`, `_ds/` — supporting files the prototype needs in order to open in a browser.
