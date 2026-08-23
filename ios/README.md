# Recipe Box for iPhone

Personal iOS app. It is not set up for the App Store. You install it on your own iPhone from Xcode.

The phone loads recipes from the hosted backend (`https://kaihkashan-recipe-box.vercel.app`). Your Mac does not need to be running. Saving from Instagram still uses the Shortcut; this app is for browsing, searching, and cooking from the box.

## Install on your iPhone

1. Open **Xcode.app** (the full app, not only Command Line Tools).
2. Open `ios/RecipeBox.xcodeproj`.
3. In the project editor → **Signing & Capabilities** → **Team**, choose **Add Account…** and sign in with your Apple ID. Use your Personal Team. You do not need a paid developer program for this.
4. Plug in the iPhone, unlock it, and tap **Trust** if asked. On the phone: **Settings → Privacy & Security → Developer Mode** (iOS 16+) if Xcode asks you to enable it.
5. In the Xcode toolbar, pick your iPhone as the run destination, then press **Run**.
6. The app talks to Vercel over the internet. If the list is empty, tap the gear and confirm the server is `https://kaihkashan-recipe-box.vercel.app`.

With a free Personal Team, the install lasts about 7 days. Run it again from Xcode to refresh.

## Using it

- Pull down to refresh after you save a new recipe.
- Filter by meal or cuisine, or tap **Favorites only**. Search by title, tag, or ingredient; tap a matching ingredient to pin it as something you have, and recipes that use those ingredients rank first.
- Open a recipe for ingredients and steps. Tap the star to favorite it, or **Edit** to fix a bad extraction — both write straight back to the Sheet.
- Swipe a recipe left to favorite it, or right to add it to your **Plan** (second tab) — a shopping checklist grouped across everything you've planned.

The phone only needs internet. Leave Settings on the Vercel URL unless you are testing a local backend.

### Editing and favoriting from the phone

Favoriting and editing send a request to the server, so if you've set `RECIPE_BOX_SECRET` (see the main README), open **Settings** on the phone and paste the same value into **Edit key**. Leave it blank against a dev server with no secret set.

## Shortcuts

Two things use the Shortcuts app:

**Saving a recipe** — the existing "Save Recipe" Shortcut from the main README's step 6. It now accepts any link `yt-dlp` recognizes (Instagram, YouTube, TikTok, ...) or a plain blog/recipe URL, no changes needed.

**Jumping into the app** — the app registers a `recipebox://` URL scheme (needs a build from Xcode with the current source to take effect on your phone). Build a Shortcut with a single **Open URLs** action pointed at one of:

| Link | What it does |
| --- | --- |
| `recipebox://surprise` | Opens a random saved recipe |
| `recipebox://plan` | Jumps straight to the Plan tab |
| `recipebox://have?items=chicken,rice` | Preloads "what I have" with that ingredient list |

For "what can I make with ___", make the ingredients dynamic instead of hardcoding them:

1. Shortcuts → **+** → name it "What can I make".
2. Add **Ask for Input** → Text → prompt "What do you have? (comma separated)".
3. Add **Text**, and set its content to `recipebox://have?items=` followed by the *Provided Input* variable from step 2 (insert it from the variable picker).
4. Add **Open URLs**, input set to that Text.
5. Optional: turn on **Show in Share Sheet** and **Add to Siri** (in the shortcut's settings, the **i** button) so you can trigger it by voice or from the share sheet.

The "surprise" and "plan" links don't need any input — just one **Open URLs** action each.
