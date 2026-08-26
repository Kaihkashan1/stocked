# Recipe Box

Share a recipe reel, video, or blog link from your iPhone. The hosted backend fetches it, asks Gemini to extract the recipe, and appends a row to a Google Sheet. Browse the collection in the iPhone app, at the Vercel URL, or in the Sheets app.

This is the free-tier MVP: Google Sheets storage, Vercel in production (optional local Mac for development). Browse at `https://kaihkashan-recipe-box.vercel.app/`, locally at `http://127.0.0.1:8000/`, or in the personal iPhone app in `ios/`.

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

1. Open [Google Sheets](https://sheets.google.com) and create a blank spreadsheet. Name it **Recipe Box**.
2. Copy the long id from the URL:

```
https://docs.google.com/spreadsheets/d/GOOGLE_SHEET_ID/edit
```

3. Put that id in `.env` as `GOOGLE_SHEET_ID`.

The first save creates the header row: Title, Servings, Ingredients, Steps, Source, Caption, Confidence, Thumbnail, Saved at, Cuisine, Meal, Time, Tags, Favorite, Notes.

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

Some recipe accounts post the actual ingredients/steps as a follow-up comment rather than putting them in the caption. This actor returns a post's first comment and a handful of its most recent comments as part of the same request — no separate call, no extra cost tier to think about — and the app prefers the post owner's own comment among those (the reliable "this is the actual recipe continuation" signal, since an early comment is often just a stray emoji from a random fan) before falling back to the first comment plus a couple of recent ones. This is a heuristic, not a guarantee: on a very popular, older post, the owner's original comment may no longer be among the handful of "latest" ones returned. It's also best-effort in the sense that any problem fetching comments never fails the save — it's extra context on top of the caption, not a requirement.

## 5. Run

```bash
source .venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

On this Mac, open [http://127.0.0.1:8000/](http://127.0.0.1:8000/) for the recipe box app. Health check: [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health).

For day-to-day use, point the iPhone Shortcut and app at the hosted URL instead of this Mac:

```
https://kaihkashan-recipe-box.vercel.app
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
   - URL: `https://kaihkashan-recipe-box.vercel.app/ingest`
   - Method: `POST`
   - Headers:
     - `Content-Type` = `application/json`
     - `X-Recipe-Box-Key` = the same value as `RECIPE_BOX_SECRET`
   - Request Body: JSON
   - Add a field `content` whose value is **Shortcut Input**
4. Add **Get Dictionary Value**. Key: `status`. Dictionary: **Contents of URL**.
5. Add **If**. Input: **Dictionary Value**. Condition: **is** `error`.
   - Inside the If, add **Show Notification**.
     - Title: `Recipe Box`
     - Body: **Get Dictionary Value**, key `error`, dictionary **Contents of URL**
   - Leave **Otherwise** empty so a successful save (or duplicate) is silent.
6. Tap **i** on the shortcut and turn **off Show When Run**.
7. In Instagram: Reel → Share → **More** → enable **Save Recipe**.

If this shortcut already exists, delete the old always-on **Show Notification**, then add the If above.

On Vercel the Shortcut waits until the recipe is saved (up to 60 seconds). A timeout still counts as an error. You can fall back to a local Mac ingest URL if that happens.

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
- **"Apify's monthly usage limit has been reached."** — your Apify account's $5/month credit is used up. Resets at the start of your next monthly cycle, or upgrade your Apify plan to raise it.

## 7. Optional: failure pushes

Create a unique topic name at [ntfy.sh](https://ntfy.sh), subscribe in the ntfy iOS app, and set `NTFY_TOPIC` in `.env`. You’ll get a ping when a save fails (or when a duplicate is skipped).

## 8. iPhone app (personal, not App Store)

A SwiftUI app lives in `ios/`. Install it on your own iPhone from Xcode with a free Apple ID. Full steps: [`ios/README.md`](ios/README.md).

Short version: open `ios/RecipeBox.xcodeproj` in **Xcode.app**, sign with your Personal Team, plug in the iPhone, press Run. The app defaults to `https://kaihkashan-recipe-box.vercel.app` — the Mac does not need to be running.

## 9. Deploy to Vercel

The web app and recipe API run on Vercel as a FastAPI function. Secrets stay in Vercel env vars — never commit `.env` or `service_account.json`.

1. Install the [Vercel CLI](https://vercel.com/docs/cli) and log in: `vercel login`
2. From this folder: `vercel --prod --yes --name recipe-box`
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

4. Redeploy after saving env vars. Production is [https://kaihkashan-recipe-box.vercel.app/](https://kaihkashan-recipe-box.vercel.app/).

Browsing the box works well on Vercel. Ingest has a **60 second** function limit, so long videos may time out in the cloud. If that happens, you can temporarily point the Shortcut at a local Mac ingest URL.

## Notes

- **The app.** Production is `https://kaihkashan-recipe-box.vercel.app/`. On this Mac, `http://127.0.0.1:8000/` is for local development. On iPhone, install the personal iOS app — see [`ios/README.md`](ios/README.md). Google Sheets remains the database.
- **Duplicates.** The same source URL is not written twice.
- **Rate limits.** Gemini 429s are retried with backoff; a quota exhausted after retries surfaces the friendly message described above rather than a raw error.
- **Sources.** Instagram goes through Apify — required, no fallback (see section 4). YouTube, TikTok, and anything else `yt-dlp` recognizes are fetched as video/caption directly — no login needed for those, since they don't require it the way Instagram does. Anything else — a recipe blog link, for example — is fetched as a plain page and its text is sent to Gemini instead. Neither yt-dlp nor the Apify actor is an official API for any of these sites; keep this as a personal tool and expect occasional breakage. If yt-dlp fetches start failing (YouTube/TikTok/blog links, not Instagram), update with `pip install -U yt-dlp`.
- **Photos** (a card, cookbook page, or screenshot) are added via the app's "Add from a photo" flow — reviewed and saved manually, not auto-ingested like a link.
- **Pantry / What I have.** A separate tab tracks ingredients you have on hand — the Recipes tab automatically sorts by closest fit to what you have, with a "% fit" badge per recipe. Independent of the ingest pipeline described above.
- **Tags.** A small fixed set (mom's recipes, veg, non-veg, dessert, high protein, airfryer) shown as quick-pick chips when adding/editing a recipe, plus free-text entry for anything else — multi-select filtering on the Recipes tab.

## Layout

```
app/
  main.py       FastAPI: app UI, GET /api/recipes, POST /ingest
  static/       Recipe box web app
  pipeline.py   Background job: fetch → extract → save
  fetch.py      Apify for Instagram, yt-dlp for other video sources, plain HTTP + text extraction otherwise
  errors.py     Shared friendly-error-message mapping (Gemini quota, Apify limit)
  extract.py    Gemini video/image/text → structured JSON
  store.py      Google Sheets append, list, categories
vercel.json     Vercel function timeout
```
