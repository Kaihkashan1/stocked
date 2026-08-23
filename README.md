# Recipe Box

Share an Instagram reel from your iPhone. A small backend on this Mac downloads it, asks Gemini to extract the recipe, and appends a row to a Google Sheet. Browse the collection in the Sheets app.

This is the free-tier MVP: Instagram only, Google Sheets storage, local Mac or Vercel. Browse on the Mac at `http://127.0.0.1:8000/`, on Vercel after deploy, or in the personal iPhone app in `ios/`. Photos and blog links can come later.

```
iPhone Share → POST /ingest → yt-dlp → Gemini → Google Sheets
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

The first save creates the header row: Title, Servings, Ingredients, Steps, Source, Caption, Confidence, Thumbnail, Saved at.

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

## 4. Shared secret and Instagram cookies

In `.env`:

- Set `RECIPE_BOX_SECRET` to any random string. The iPhone Shortcut will send it as a header so random LAN traffic can’t ingest into your sheet. Leave `change-me` only while you are testing with curl.
- Point `YTDLP_COOKIES_FILE` at `./instagram_cookies.txt`. Instagram usually blocks anonymous downloads. Export **only** `instagram.com` cookies into that file so the app never reads your Safari cookie jar.

### Export Instagram-only cookies

1. Log into Instagram in **Chrome or Firefox** (extensions for this are reliable there; Safari is not).
2. Install a cookies exporter such as [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) (Chrome) or the Firefox equivalent.
3. While on `instagram.com`, export cookies. Prefer an option that limits the export to `instagram.com` / `.instagram.com`.
4. Save the file in this project as `instagram_cookies.txt` (same folder as `README.md`). It should look like a Netscape cookie file (lines with `instagram.com` and tab-separated fields).
5. This file is a login token. It is gitignored. Don’t share it.

When Instagram logs you out, export a fresh file and replace this one.

## 5. Check setup, then run

```bash
source .venv/bin/activate
python -m app.check
```

If that prints `All checks passed`:

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

On this Mac, open [http://127.0.0.1:8000/](http://127.0.0.1:8000/) for the recipe box app. Health check: [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health).

Find your Mac’s Wi-Fi address (iPhone and Mac on the same network):

```bash
ipconfig getifaddr en0
```

That value (something like `192.168.1.23`) is what the Shortcut will call. Allow incoming connections if macOS Firewall asks.

## 6. iPhone Shortcut

On the iPhone:

1. Open **Shortcuts → All Shortcuts → +**. Name it **Save Recipe**.
2. Tap the **i** (or shortcut settings) and turn on **Show in Share Sheet**. Accept **URLs** and **Text**.
3. Add action **Get Contents of URL**:
   - URL: `http://YOUR_MAC_IP:8000/ingest`
   - Method: `POST`
   - Headers:
     - `Content-Type` = `application/json`
     - `X-Recipe-Box-Key` = the same value as `RECIPE_BOX_SECRET`
   - Request Body: JSON
   - Add a field `content` whose value is **Shortcut Input**
4. Add **Show Notification**. Body: **Contents of URL** (the JSON response). You want to see `"status":"queued"`.
5. In Instagram: Reel → Share → **More** → enable **Save Recipe**.

The Shortcut returns immediately. The Mac then downloads, extracts, and writes the row. Watch the Terminal for logs, or hit `GET /jobs` with the same header.

Test without the phone, from the Mac:

```bash
curl -X POST http://127.0.0.1:8000/ingest \
  -H "Content-Type: application/json" \
  -H "X-Recipe-Box-Key: change-me" \
  -d '{"content":"https://www.instagram.com/reel/PASTE_A_REEL_ID/"}'
```

Then `curl http://127.0.0.1:8000/jobs -H "X-Recipe-Box-Key: change-me"` and refresh the Sheet.

## 7. Optional: failure pushes

Create a unique topic name at [ntfy.sh](https://ntfy.sh), subscribe in the ntfy iOS app, and set `NTFY_TOPIC` in `.env`. You’ll get a ping when a save fails (or when a duplicate is skipped).

## 8. iPhone app (personal, not App Store)

A SwiftUI app lives in `ios/`. Install it on your own iPhone from Xcode with a free Apple ID. Full steps: [`ios/README.md`](ios/README.md).

Short version: start the backend on this Mac, open `ios/RecipeBox.xcodeproj` in **Xcode.app**, sign with your Personal Team, plug in the iPhone, press Run. In the app, set the server to `http://YOUR_MAC_IP:8000` if it isn’t already. After a Vercel deploy, you can point the app at `https://YOUR_PROJECT.vercel.app` instead.

## 9. Deploy to Vercel

The web app and recipe API run on Vercel as a FastAPI function. Secrets stay in Vercel env vars — never commit `.env`, `service_account.json`, or `instagram_cookies.txt`.

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
   | `YTDLP_COOKIES` | full contents of `instagram_cookies.txt` (only if you want cloud ingest) |
   | `NTFY_TOPIC` | optional |

4. Redeploy after saving env vars. Open `https://YOUR_PROJECT.vercel.app/` to browse recipes.

Browsing the box works well on Vercel. Instagram ingest has a **60 second** function limit, so long reels may time out in the cloud. Keep the Mac backend for saving from the Shortcut if that happens; the iPhone app can still read from the Vercel URL.

## Notes

- **The app.** On this Mac open `http://127.0.0.1:8000/`. After deploy, use the Vercel URL. On iPhone, install the personal iOS app — see [`ios/README.md`](ios/README.md). Google Sheets remains the database.
- **Duplicates.** The same reel URL is not written twice.
- **Rate limits.** Gemini 429s are retried with backoff.
- **Instagram.** `yt-dlp` is not an official Instagram API. Keep this as a personal tool; expect occasional breakage when Instagram changes something. If fetches start failing, update with `pip install -U yt-dlp` and re-export `instagram_cookies.txt`.
- **Photos and blog links** are not wired yet. The `/ingest` endpoint will reject anything that isn’t an Instagram URL.

## Layout

```
app/
  main.py       FastAPI: app UI, GET /api/recipes, POST /ingest
  static/       Recipe box web app
  pipeline.py   Background job: fetch → extract → save
  fetch.py      Instagram via yt-dlp
  extract.py    Gemini video/image → structured JSON
  store.py      Google Sheets append, list, categories
  backfill.py   python -m app.backfill  (categorize old rows)
  check.py      python -m app.check
vercel.json     Vercel function timeout
```
