# Recipe Box for iPhone

Personal iOS app. It is not set up for the App Store. You install it on your own iPhone from Xcode.

The phone loads recipes from the hosted backend (`https://recipe-box-ashen-alpha.vercel.app`). Your Mac does not need to be running. Saving from Instagram still uses the Shortcut; this app is for browsing, searching, and cooking from the box.

## Install on your iPhone

1. Open **Xcode.app** (the full app, not only Command Line Tools).
2. Open `ios/RecipeBox.xcodeproj`.
3. In the project editor → **Signing & Capabilities** → **Team**, choose **Add Account…** and sign in with your Apple ID. Use your Personal Team. You do not need a paid developer program for this.
4. Plug in the iPhone, unlock it, and tap **Trust** if asked. On the phone: **Settings → Privacy & Security → Developer Mode** (iOS 16+) if Xcode asks you to enable it.
5. In the Xcode toolbar, pick your iPhone as the run destination, then press **Run**.
6. The app talks to Vercel over the internet. If the list is empty, tap the gear and confirm the server is `https://recipe-box-ashen-alpha.vercel.app`.

With a free Personal Team, the install lasts about 7 days. Run it again from Xcode to refresh.

## Using it

- Pull down to refresh after you save a new Instagram recipe.
- Filter by meal or cuisine, search by title, ingredient, or tag, or pick **What I have** so recipes that use those ingredients rank with the closest fit first.
- Open a recipe for ingredients and steps.

The phone only needs internet. Leave Settings on the Vercel URL unless you are testing a local backend.
