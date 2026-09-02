# Stocked for iPhone

Personal iOS app (home-screen name **Stocked**). It is not set up for the App Store. You install it on your own iPhone from Xcode.

The phone loads data from the hosted backend (`https://stocked-cookbook-cupboard.vercel.app`). Your Mac does not need to be running. Saving from Instagram still uses the Shortcut; this app is for browsing, filtering, cooking, and managing your cupboard.

Two tabs:

| Tab | What it is |
| --- | --- |
| **Cookbook** | Your recipes — search, filters, fit ranking, cook mode |
| **Cupboard** | Kitchen stock (Items) + shopping checklist (To buy) |

Those are separate on purpose. Marking ingredients on the Cookbook list does **not** add Cupboard inventory, and Cupboard stock does **not** drive the recipe fit filter.

## Install on your iPhone

1. Open **Xcode.app** (the full app, not only Command Line Tools).
2. Open `ios/RecipeBox.xcodeproj` (or the `RecipeBox.xcworkspace` in this repo). The Xcode project name is still RecipeBox; the home-screen name is Stocked. In the toolbar scheme menu, choose **RecipeBox**. If that menu is empty: **Product → Scheme → Manage Schemes…** → tick **RecipeBox** (shared) → Close.
3. In the project editor → **Signing & Capabilities** → **Team**, choose **Add Account…** and sign in with your Apple ID. Use your Personal Team. You do not need a paid developer program for this.
4. Plug in the iPhone, unlock it, and tap **Trust** if asked. On the phone: **Settings → Privacy & Security → Developer Mode** (iOS 16+) if Xcode asks you to enable it.
5. In the Xcode toolbar, pick your iPhone as the run destination, then press **Run**.
6. The app talks to Vercel over the internet. If the list is empty, tap the gear and confirm the server is `https://stocked-cookbook-cupboard.vercel.app`.

With a free Personal Team, Apple’s signature on the app lasts about **7 days**. After that, tapping Stocked on the phone does nothing (or says the developer is untrusted) until you plug in and **Run** from Xcode again — that only renews the signature; it does not wipe recipes. A paid Apple Developer account / TestFlight is needed if someone else should keep the app without weekly Xcode. There are no user accounts or household invites: one Vercel URL and Edit key is one shared cookbook.

The Home Screen icon is the book-over-shelf mark in `Assets.xcassets`. If an install shows a blank glyph, delete Stocked from the phone, clean the build folder, and Run again.

## Cookbook

- Pull down to refresh after you save a new recipe. Opening the app again (from the home screen or after it sat in the background) also refreshes Cookbook and Cupboard from the server. Coming back online after a drop does the same.
- After a successful sync, recipes and cupboard data stay on the phone. You can browse, filter, and cook **offline**. A sage banner reads **Offline — showing recipes saved on this phone**. Adding recipes, favoriting, editing, deleting, and cupboard writes still need the network.
- **Search recipes** filters the list by title/text as you type. If what you typed also matches an ingredient name, a row under search lets you **filter by ingredient** — tap a suggestion, or **+ Add "…"** for a custom name.
- Next to search: a **filter** button (fills accent when any list filter is active) and a **grid/list toggle** for recipe cards (remembered on this phone).
- A **Main course / Appetizers / Desserts / Dips** row sits below search — tap one to filter, tap again to clear.
- Ingredient filters are **AND**: only recipes that use **all** selected ingredients stay visible. Results are ranked by **fit %** (sage **% FIT** pill on each card). Sort (Recent / A–Z / Z–A) is ignored while ingredient filters are active. The sage banner reads **Filtered by …** with **Clear**.
- **Clear all filters** appears on the list whenever search, course, tags, sources, favorites, or ingredients are narrowing it.
- **Filters** sheet, in order: **Ingredients** (only if any are selected — same sage card as before), **Favorites only**, **Sort**, **Source** (Instagram / YouTube / TikTok / Link / Photo / Typed in), **Tags**. **Reset** clears everything including ingredients.
- **+** offers four ways to add: **Paste a link**, **Take a photo** / **Choose from library**, and **Type it in**.
- Open a recipe for ingredients (scale ½× / 1× / 2× / 3×), steps, course pill, and **Start cooking**. Each ingredient row has a **+ / ✓** control that adds or removes that line on the Cupboard **To buy** list (quantity prefilled from the chip when present). Custom header (not the system nav bar): inset-ring **back**, favorite, and **⋯**. The ⋯ menu tucks 6pt under that circle (accent ring while open): original post when linked, edit, delete — Figtree labels and Lucide-style glyphs. Delete asks **Delete this recipe?** (Cancel + terracotta Delete). Edit covers title, course, tags, ingredients (`qty | item`), steps, and notes.

## Cupboard

- Header kicker: `N items · M to buy`. Segments: **Items** / **To buy**.
- **Items**: search with **Search what's in stock** (name or category). **Select items to match** finds recipes that use selected stock (best-effort, independent of Cookbook fit %). Add/edit sheet: name, category, amount + unit, open/unopened, optional expiry, notes. Expiry badges: outline date when far out; sage **Expires in Nd** at 4–7 days; terracotta **Expires in 2d** / **Expires today** inside 3 days; **Expired** once past.
- **To buy**: search with **Search items to buy**, then add field + checklist. Each row has a **qty** pill (editable; recipe adds prefill it). Stock and to-buy searches are independent — switching segments does not clear the other.

## Settings

Favoriting, editing, and Cupboard writes need the server secret when `RECIPE_BOX_SECRET` is set: open **Settings** and paste it into **Edit key**. Leave blank against a dev server with no secret.

Settings also shows **API usage** — today's Gemini reads vs the free daily cap, and this month's Apify spend vs credit (Apify half only when `APIFY_API_TOKEN` is set on the server).

Default server URL is `https://stocked-cookbook-cupboard.vercel.app`. Older installs pointed at `kaihkashan-recipe-box.vercel.app` migrate automatically on launch.

## Shortcuts

**Saving a recipe** — the existing "Save Recipe" Shortcut from the main README. It accepts any link `yt-dlp` recognizes (Instagram, YouTube, TikTok, …) or a plain blog/recipe URL.

**Jumping into the app** — `recipebox://` URL scheme (needs a current Xcode build on the phone):

| Link | What it does |
| --- | --- |
| `recipebox://surprise` | Opens a random saved recipe |
| `recipebox://cupboard` | Opens the **Cupboard** tab |
| `recipebox://pantry` | Same as cupboard (older shortcuts) |
| `recipebox://have?items=chicken,rice` | Replaces the Cookbook ingredient filter with that list |

For "what can I make with ___":

1. Shortcuts → **+** → name it "What can I make".
2. Add **Ask for Input** → Text → prompt "Ingredients? (comma separated)".
3. Add **Text**: `recipebox://have?items=` + the *Provided Input* variable.
4. Add **Open URLs** pointed at that Text.
5. Optional: **Show in Share Sheet** / **Add to Siri**.

## Design reference

Interactive prototype and tokens live in [`design_handoff_recipe_box/`](../design_handoff_recipe_box/) (`Recipe Box.dc.html`, `AppIcon.dc.html`, README). The SwiftUI app under `ios/RecipeBox/` is the implementation.
