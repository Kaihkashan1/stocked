# Recipe Box for iPhone

Personal iOS app. It is not set up for the App Store. You install it on your own iPhone from Xcode.

The phone talks to the Python backend on this Mac over Wi-Fi. Saving from Instagram still uses the Shortcut; this app is for browsing, searching, and cooking from the box.

## Install on your iPhone

1. On the Mac, start the backend:

   ```bash
   source .venv/bin/activate
   uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```

2. Note the Mac’s Wi-Fi IP:

   ```bash
   ipconfig getifaddr en0
   ```

3. Open **Xcode.app** (the full app, not only Command Line Tools).
4. Open `ios/RecipeBox.xcodeproj`.
5. In the project editor → **Signing & Capabilities** → **Team**, choose **Add Account…** and sign in with your Apple ID. Use your Personal Team. You do not need a paid developer program for this.
6. Plug in the iPhone, unlock it, and tap **Trust** if asked. On the phone: **Settings → Privacy & Security → Developer Mode** (iOS 16+) if Xcode asks you to enable it.
7. In the Xcode toolbar, pick your iPhone as the run destination, then press **Run**.
8. The first launch may ask to allow **local network** access. Allow it.
9. If the list is empty, tap the gear and set the server to `http://YOUR_MAC_IP:8000`, or to your Vercel URL (`https://YOUR_PROJECT.vercel.app`) after the backend is deployed.

With a free Personal Team, the install lasts about 7 days. Run it again from Xcode to refresh.

## Using it

- Pull down to refresh after you save a new Instagram recipe.
- Filter by meal or cuisine, search by title, ingredient, or tag, or pick **What I have** so recipes that use those ingredients rank with the closest fit first.
- Open a recipe for ingredients and steps.

Mac and iPhone must stay on the same Wi-Fi. If the Mac sleeps or its IP changes, update Settings in the app.
