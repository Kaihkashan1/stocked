# Stocked

Share a recipe reel, video, or blog link from your iPhone. The hosted backend fetches it, asks Gemini to extract the recipe, and appends a row to a Google Sheet. Browse and cook in the personal iPhone app (**Stocked** — Cookbook + Cupboard tabs), at the Vercel URL, or in the Sheets app.

This is the free-tier MVP: Google Sheets storage, Vercel in production (optional local Mac for development). Production: `https://stocked-cookbook-cupboard.vercel.app/`. Local: `http://127.0.0.1:8000/`. iPhone app: [`ios/`](ios/).

```
iPhone Share → POST /ingest → Apify (Instagram) / yt-dlp (YouTube, TikTok, ...) / plain page fetch (everything else) → Gemini → Google Sheets
```

## 1. Install the app

You need Python 3.11 or newer. In Terminal, from this folder:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Leave `.env` open — the next two sections fill it.

## 2. Gemini API key (free)

1. Open [Google AI Studio](https://aistudio.google.com/apikey) and sign in with a Google account.
2. Create an API key. No credit card is required for this step.
3. Paste it into `.env`:

```
GEMINI_API_KEY=your-key-here
```

Free-tier content may be used to improve Google’s models. Fine for recipe videos; don’t send anything sensitive with this key.

Rate limits live at [aistudio.google.com/rate-limit](https://aistudio.google.com/rate-limit). A handful of recipes a day stays under typical free-tier caps.

## 3. Google Sheet + service account (free)

The backend writes as a bot, so it needs a Google Cloud *service account* that you’ve shared the Sheet with.

### Create the spreadsheet

1. Open [Google Sheets](https://sheets.google.com) and create a blank spreadsheet. Name it **Stocked** (or keep an existing “Recipe Box” sheet — only the id matters).
2. Copy the long id from the URL:

```
https://docs.google.com/spreadsheets/d/GOOGLE_SHEET_ID/edit
```

3. Put that id in `.env` as `GOOGLE_SHEET_ID`.

The first save creates the header row: Title, Ingredients, Steps, Source, Confidence, Saved at, Tags, Favorite, Notes, Course.

### Create a service account

1. Open [Google Cloud Console](https://console.cloud.google.com/). Sign in with the same Google account.
2. Create a project (e.g. `recipe-box`). Billing is not required for the Sheets API at this volume; skip any billing prompts if you can.
3. Enable **Google Sheets API** and **Google Drive API**:
   - [Sheets API](https://console.cloud.google.com/apis/library/sheets.googleapis.com)
   - [Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com)
4. Go to **APIs & Services → Credentials → Create credentials → Service account**.
5. Name it `recipe-box`, skip optional steps, click **Done**.
6. Open the service account → **Keys → Add key → Create new key → JSON**. Save the downloaded file in this project as `service_account.json` (same folder as `README.md`).
7. Open that JSON file and copy `client_email` (looks like `recipe-box@….iam.gserviceaccount.com`). For this project it is `recipe-box@recipe-box-506315.iam.gserviceaccount.com`.
8. Back in the Sheet: **Share →** paste that email → **Editor** → uncheck “Notify people” → **Share**.

If you skip that last share step, every save will fail with “Spreadsheet not found.”

## 4. Shared secret and Instagram fetching

In `.env`:

- Set `RECIPE_BOX_SECRET` to any random string. The iPhone Shortcut will send it as a header so random LAN traffic can’t ingest into your sheet. Leave `change-me` only while you are testing with curl.
- Set up Apify for Instagram links (below). There is no other way to fetch Instagram content in this app — no personal login, no cookies. Without a token, Instagram links will fail with a clear error; every other source (YouTube, TikTok, blog links) works without Apify.

### Apify (required for Instagram — no login involved)

1. Create a free Apify account at [apify.com](https://apify.com) — no credit card required.
2. Find your API token in Apify Console → **Settings → API & Integrations**.
3. Set `APIFY_API_TOKEN` in `.env` to that token. Leave `APIFY_INSTAGRAM_ACTOR` at its default (`apify~instagram-post-scraper`) unless you want to try a different one from the Apify Store.
4. No card, no automatic charges: the free plan gives $5/month of usage and can't spend past it — it just blocks further runs until the next cycle, never bills you.

**Which actor, and why**: this uses Apify's own officially-maintained `apify/instagram-post-scraper` — not a third-party community actor. That choice matters in practice: several community actors from the same developer (e.g. `apidojo/instagram-scraper-api`) impose their own extra "free users: 5 runs/month" throttle *on top of* Apify's platform billing, which would cap you at ~5 Instagram saves a month regardless of how much of your $5 credit is left. The official actor used here has no such throttle, a much larger track record (100K+ users vs. low thousands), and costs less per post (~$0.001 vs ~$0.005) — the real ceiling is just Apify's $5/month credit, which at this actor's pricing is roughly 1,000 saves/month.

Some recipe accounts post the actual ingredients/steps as a follow-up comment rather than putting them in the caption. This actor returns a post's first comment and a handful of its most recent comments as part of the same request — no separate call, no extra cost tier to think about — and the app prefers the post owner's own comment among those (the reliable "this is the actual recipe continuation" signal, since an early comment is often just a stray emoji from a random fan) before falling back to the first comment plus a couple of recent ones.

If the owner's comment isn't in that first handful, the app makes one more call — to `apify/instagram-scraper` (`APIFY_COMMENTS_ACTOR`, default already set) in its dedicated comments mode — searching up to 15 of the post's newest comments (the free-tier cap on that actor) instead of just a few. This is a real gap it closes, confirmed against an actual recipe: the primary actor's own small sample missed the owner's comment entirely. This fallback is skipped entirely on Vercel, same reasoning as the main fetch's own budget note above — it's a second sequential network call, and there's no safe room for it within the 60s function limit; it only runs locally or in a background task. Any problem here is logged and skipped, never fails the save — it's extra context on top of the caption, not a requirement.

**Known limitation: pinned comments aren't reachable.** On a very popular post, even 15 newest comments can all be people asking "recipe?" (a common trigger for a private DM auto-reply bot — not reachable by any scraper, since it's a private message). Worse: if the creator has *pinned* their own recipe comment to the top — confirmed as the actual cause on a real recipe, via Instagram's own "Pinned" label on the comment — no amount of searching "newest" comments finds it, because it can be arbitrarily old. This was investigated directly, not assumed: three different Apify actors (`apify/instagram-post-scraper`, `apify/instagram-scraper`, `apify/instagram-comment-scraper`, including Apify's own official ones) were tested live against the exact post in question — none expose an `isPinned`-style field anywhere in their output, and all three cap comments at 15 sorted "newest," regardless of requested limit, on the free tier. A related feature request on `apify/instagram-scraper`'s own issue tracker (asking for sort-by-likes/views instead of just newest) got this answer directly from an Apify developer: *"We can not support such a feature because it is not supported by Instagram... there is no way to change it in the webapp, so the actor is forced to follow the same sorting."* That points at pinned-comment status simply not being part of the public, logged-out API surface these scrapers can reach at all — the same category of limitation as the DM-bot case, not a bug in this app's comment-selection logic. When this happens, quantities will be missing (Gemini had nothing to extract them from) and need adding manually — same as always when the source genuinely doesn't have the information available to it.

## 5. Run

```bash
source .venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

On this Mac, open [http://127.0.0.1:8000/](http://127.0.0.1:8000/) for the web UI. Health check: [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health).

For day-to-day use, point the iPhone Shortcut and Stocked app at the hosted URL instead of this Mac:

```
https://stocked-cookbook-cupboard.vercel.app
```

A local server is only needed when you are developing the backend. If you do use LAN ingest, find this Mac’s Wi-Fi address (iPhone and Mac on the same network):

```bash
ipconfig getifaddr en0
```

That value (something like `192.168.1.23`) is what a local Shortcut would call. Allow incoming connections if macOS Firewall asks.

## 6. iPhone Shortcut

On the iPhone:

1. Open **Shortcuts → All Shortcuts → +**. Name it **Save Recipe**.
2. Tap the **i** (or shortcut settings) and turn on **Show in Share Sheet**. Accept **URLs** and **Text**.
3. Add action **Get Contents of URL**:
   - URL: `https://stocked-cookbook-cupboard.vercel.app/ingest`
   - Method: `POST`
   - Headers:
     - `Content-Type` = `application/json`
     - `X-Recipe-Box-Key` = the same value as `RECIPE_BOX_SECRET`
   - Request Body: JSON
   - Add a field `content` whose value is **Shortcut Input**
   - Tap **Show More** and set **Request Timeout** to `65` — a few seconds past Vercel's own 60s ceiling (below), so this action isn't the thing that cuts the request short.
4. Add **If**. Input: **Contents of URL**. Condition: **Contains**. Value: `status` (as plain text — this checks the raw response text, not a parsed field).
   - **This distinguishes a real timeout from everything else**: a genuine response from this app is always JSON with a `status` key, whether it's a success, a duplicate, or a caught error (Gemini quota, Apify limit, anything else `errors.py` handles) — the backend deliberately returns HTTP 200 with `status: "error"` for all of those (see `app/pipeline.py`), specifically so this check can tell them apart from a hard failure. A genuine timeout or network failure means Vercel's platform killed the function before the app ever got to respond, so the reply has no `status` key at all — it's a Vercel-branded error, not this app's JSON.
   - **Inside the If (has "status" — a real response came back):**
     - Add **Get Dictionary Value**. Key: `status`. Dictionary: **Contents of URL**.
     - Add a nested **If**. Input: **Dictionary Value**. Condition: **is** `error`.
       - Inside: **Show Notification** — Title: `Stocked`, Body: **Get Dictionary Value**, key `error`, dictionary **Contents of URL**. This is where the Gemini-quota and Apify-limit messages actually show up — each has distinct wording (see section below), so the notification itself tells you which one it was.
       - Leave that inner **Otherwise** empty — a successful save or a duplicate stays silent.
   - **In the outer If's Otherwise (no "status" — the request never got a real response):**
     - Add **Show Notification** — Title: `Stocked`, Body: `Request timed out or failed before the server could respond (Vercel's ingest limit is 60s). The recipe probably wasn't saved — try again in a bit.`
5. Tap **i** on the shortcut and turn **off Show When Run**.
6. In Instagram: Reel → Share → **More** → enable **Save Recipe**.

If this shortcut already exists from before, delete the old flat "get status → if error → notify" chain and rebuild it with the outer If above wrapped around it — that outer check is what actually catches a timeout instead of letting it pass silently as if nothing happened, which is what the older version did.

I can't see your actual Shortcuts app screen, so if a step doesn't match what you see (Apple does shuffle this UI between iOS versions), tell me exactly what you're looking at and we'll adjust together.

On Vercel the Shortcut waits until the recipe is saved (up to 60 seconds). You can fall back to a local Mac ingest URL if timeouts are a recurring problem.

Test without the phone, from the Mac:

```bash
curl -X POST http://127.0.0.1:8000/ingest \
  -H "Content-Type: application/json" \
  -H "X-Recipe-Box-Key: change-me" \
  -d '{"content":"https://www.instagram.com/reel/PASTE_A_REEL_ID/"}'
```

Then `curl http://127.0.0.1:8000/jobs -H "X-Recipe-Box-Key: change-me"` and refresh the Sheet.

### Where errors actually show up

There's no error screen in the app itself for a failed `/ingest` call — the message reaches you through whichever of these you've set up:

- **The Shortcut's own notification** (step 5 above) — an iOS notification banner right after sharing, showing the real message. This is the main channel if you built the Shortcut as described.
- **ntfy push** (next section) — a second, optional channel, useful as a backup or if you don't want the Shortcut's own notification.
- **`curl .../jobs`** — a protected debug endpoint showing recent job history; not really "in the app," more a manual check.

If you skip both the Shortcut's notification step and ntfy, a failed save is silent — you'd only notice because the recipe never showed up.

Two specific messages worth knowing about, since both are common on a personal/free setup:

- **"Gemini's free daily quota (20 requests/day) is used up."** — Gemini's free tier caps at 20 requests/day across every save method except manual typing (photos, Instagram, YouTube/TikTok, and blog links all call Gemini; typing a recipe in by hand doesn't). Resets at midnight Pacific.
- **"Apify's monthly usage limit has been reached."** — your Apify account's $5/month credit is used up. This resets on your personal Apify **billing-cycle anniversary** (visible in Apify Console → Billing → Current period) — not the 1st of the calendar month, which is a common mix-up since Apify's own usage charts default to calendar-month view. Or upgrade your Apify plan to raise it sooner.

## 7. Optional: failure pushes

Create a unique topic name at [ntfy.sh](https://ntfy.sh), subscribe in the ntfy iOS app, and set `NTFY_TOPIC` in `.env`. You’ll get a ping when a save fails (or when a duplicate is skipped).

## 8. iPhone app — Stocked (personal, not App Store)

A SwiftUI app lives in `ios/` (Xcode project still named RecipeBox; home-screen name is **Stocked**). Two tabs: **Cookbook** (recipes) and **Cupboard** (inventory + to-buy). Full steps: [`ios/README.md`](ios/README.md).

Short version: open `ios/RecipeBox.xcodeproj` in **Xcode.app**, sign with your Personal Team, plug in the iPhone, press Run. The app defaults to `https://stocked-cookbook-cupboard.vercel.app` — the Mac does not need to be running. Older phones still pointing at `kaihkashan-recipe-box.vercel.app` are migrated to the new host on launch.

## 9. Deploy to Vercel

The web app and recipe API run on Vercel as a FastAPI function. Secrets stay in Vercel env vars — never commit `.env` or `service_account.json`.

1. Install the [Vercel CLI](https://vercel.com/docs/cli) and log in: `vercel login`
2. From this folder: `vercel --prod --yes` (this project deploys as **stocked-cookbook-cupboard**)
3. In the Vercel project → Settings → Environment Variables, add:

   | Name | Value |
   | --- | --- |
   | `GEMINI_API_KEY` | same as `.env` |
   | `GEMINI_MODEL` | `gemini-3.6-flash` |
   | `GOOGLE_SHEET_ID` | same as `.env` |
   | `GOOGLE_SERVICE_ACCOUNT_JSON` | full contents of `service_account.json` |
   | `RECIPE_BOX_SECRET` | same as `.env` |
   | `APIFY_API_TOKEN` | same as `.env` — required for Instagram links |
   | `NTFY_TOPIC` | optional |

4. Redeploy after saving env vars. Production is [https://stocked-cookbook-cupboard.vercel.app/](https://stocked-cookbook-cupboard.vercel.app/).

Browsing the box works well on Vercel. Ingest has a **60 second** function limit, so long videos may time out in the cloud. If that happens, you can temporarily point the Shortcut at a local Mac ingest URL.

## Notes

- **The app.** Production is `https://stocked-cookbook-cupboard.vercel.app/`. On this Mac, `http://127.0.0.1:8000/` is for local development. On iPhone, install **Stocked** — see [`ios/README.md`](ios/README.md). Google Sheets remains the recipe database; Cupboard inventory and to-buy live in App State JSON on the server (not Sheet rows).
- **Duplicates.** The same source URL is not written twice.
- **Rate limits.** Gemini 429s are retried with backoff; a quota exhausted after retries surfaces the friendly message described above rather than a raw error.
- **Sources.** Instagram goes through Apify — required, no fallback (see section 4). YouTube, TikTok, and anything else `yt-dlp` recognizes are fetched as video/caption directly — no login needed for those, since they don't require it the way Instagram does. Anything else — a recipe blog link, for example — is fetched as a plain page and its text is sent to Gemini instead. Neither yt-dlp nor the Apify actor is an official API for any of these sites; keep this as a personal tool and expect occasional breakage. If yt-dlp fetches start failing (YouTube/TikTok/blog links, not Instagram), update with `pip install -U yt-dlp`.
- **Photos** (a card, cookbook page, or screenshot) are added via the app's photo add flow — reviewed and saved manually, not auto-ingested like a link.
- **Cookbook ingredient filter** (`GET`/`PUT /api/pantry`). Flat string list used only on the Cookbook tab: type in search to mark ingredients, **AND**-filter recipes that use all of them, rank by **fit %**, sage banner **Filtered by …**. Synced across devices. This is **not** kitchen inventory.
- **Cupboard** (`GET`/`PUT /api/pantry-inventory`, `GET`/`PUT /api/to-buy`). Separate stock rows (amount, unit, open/unopened, expiry, notes) plus a to-buy checklist with optional **qty**. Match mode on Items suggests recipes from selected stock. Recipe detail **+** toggles a line onto to-buy (qty prefilled from the ingredient chip). Independent of the Cookbook ingredient filter and of ingest.
- **Tags.** A small fixed set (mom's recipes, veg, non-veg, dessert, high protein, airfryer) shown as quick-pick chips when adding/editing a recipe — enforced at the model layer. Multi-select filtering on Cookbook.
- **Course.** Every recipe is Main course, Appetizers, or Desserts — Sheet column, Cookbook filter row, detail pill. `/ingest` derives it from Gemini's meal classification; add/edit flows (including Edit recipe) set it directly.
- **API usage.** Settings shows today's Gemini read count against the free tier's 20/day cap (self-tracked), and this month's Apify spend against live credit (when `APIFY_API_TOKEN` is set), each with when it resets.
- **Design handoff.** Visual/interaction reference for the iOS redesign: [`design_handoff_recipe_box/`](design_handoff_recipe_box/).

## Layout

```
app/
  main.py       FastAPI: web UI, recipes CRUD, pantry / pantry-inventory / to-buy, usage, POST /ingest
  static/       Web browse UI
  pipeline.py   Background job: fetch → extract → save
  fetch.py      Apify for Instagram, yt-dlp for other video sources, plain HTTP + text extraction otherwise
  errors.py     Shared friendly-error-message mapping (Gemini quota, Apify limit)
  extract.py    Gemini video/image/text → structured JSON
  store.py      Google Sheets + App State (inventory, to-buy, flat pantry filter)
  models.py     Recipe, PantryItem, ToBuyItem, …
ios/            Stocked (SwiftUI) — Cookbook + Cupboard
design_handoff_recipe_box/   Interactive prototype + app icon
vercel.json     Vercel function timeout
```
