#!/usr/bin/env python3
"""Write ios/RecipeBox/Localizable.xcstrings from English → German pairs."""

from __future__ import annotations

import json
from pathlib import Path

# Simple strings: catalog key is the English source.
SIMPLE = {
    "Cookbook": "Kochbuch",
    "Cupboard": "Vorrat",
    "Stocked": "Stocked",
    "Settings": "Einstellungen",
    "Close": "Schließen",
    "Filters": "Filter",
    "Reset": "Zurücksetzen",
    "Done": "Fertig",
    "Cancel": "Abbrechen",
    "Save": "Sichern",
    "Saving…": "Wird gespeichert…",
    "Delete": "Löschen",
    "Deleting…": "Wird gelöscht…",
    "OK": "OK",
    "Back": "Zurück",
    "More": "Mehr",
    "Clear": "Löschen",
    "Paste": "Einsetzen",
    "Items": "Artikel",
    "To buy": "Einkaufen",
    "Ingredients": "Zutaten",
    "Steps": "Schritte",
    "Notes": "Notizen",
    "New tag": "Neues Tag",
    "Title": "Titel",
    "Course": "Gang",
    "Tags": "Tags",
    "Sort": "Sortierung",
    "Source": "Quelle",
    "Category": "Kategorie",
    "Amount": "Menge",
    "Unit": "Einheit",
    "Status": "Status",
    "Server": "Server",
    "Edit key": "Bearbeitungsschlüssel",
    "English": "Englisch",
    "German": "Deutsch",
    "Deutsch": "Deutsch",
    "Language": "Sprache",
    "System": "System",
    "Developer": "Entwickler",
    "Import limits": "Importlimits",
    "Imports today": "Importe heute",
    "Import cost this month": "Importkosten diesen Monat",
    "What I have": "Was ich habe",
    "Nothing marked yet.": "Noch nichts markiert.",
    "Sorts recipes by closest fit. Type an ingredient in search to add one.": "Sortiert Rezepte nach der besten Passung. Tippe in der Suche eine Zutat, um eine hinzuzufügen.",
    "Recipes load from the hosted server. Your Mac does not need to be running.": "Rezepte kommen vom gehosteten Server. Dein Mac muss nicht laufen.",
    "Only needed to favorite or edit. Same value the Shortcut sends.": "Nur zum Favorisieren oder Bearbeiten nötig. Derselbe Wert, den der Kurzbefehl sendet.",
    "API usage": "API-Nutzung",
    "FIT": "PASSEND",
    "Favorites only": "Nur Favoriten",
    "Add recipe": "Rezept hinzufügen",
    "Add tag": "Tag hinzufügen",
    "Add a recipe": "Rezept hinzufügen",
    "Edit recipe": "Rezept bearbeiten",
    "Delete recipe": "Rezept löschen",
    "Original post": "Originalbeitrag",
    "Start cooking": "Kochen starten",
    "Next step": "Nächster Schritt",
    "Done cooking": "Fertig gekocht",
    "Get started": "Loslegen",
    "Add your first recipe": "Dein erstes Rezept hinzufügen",
    "Paste a link": "Link einfügen",
    "Take a photo": "Foto aufnehmen",
    "Choose from library": "Aus der Mediathek",
    "Type it in": "Selbst eintippen",
    "From a photo": "Aus einem Foto",
    "Save recipe": "Rezept speichern",
    "Reading…": "Wird gelesen…",
    "Open the recipe": "Rezept öffnen",
    "Save and reload": "Sichern und neu laden",
    "Save changes": "Änderungen sichern",
    "Add to cupboard": "Zum Vorrat hinzufügen",
    "Add cupboard item": "Artikel hinzufügen",
    "Edit cupboard item": "Artikel bearbeiten",
    "Add to favorites": "Zu Favoriten hinzufügen",
    "Remove from favorites": "Aus Favoriten entfernen",
    "Add to buy": "Zur Einkaufsliste",
    "Select items to match": "Artikel zum Abgleichen wählen",
    "Done matching": "Abgleich beenden",
    "Filter by ingredient": "Nach Zutat filtern",
    "Clear all filters": "Alle Filter löschen",
    "Search recipes": "Rezepte suchen",
    "Search what's in stock": "Vorrat durchsuchen",
    "Search items to buy": "Einkaufsliste durchsuchen",
    "What is it?": "Was ist das?",
    "Optional": "Optional",
    "e.g. 200": "z. B. 200",
    "qty": "Menge",
    "Add something to buy…": "Etwas zum Kaufen hinzufügen…",
    "https://…": "https://…",
    "Only needed to favorite/edit": "Nur zum Favorisieren/Bearbeiten nötig",
    "No expiry": "Kein Ablaufdatum",
    "Date set": "Datum gesetzt",
    "Expiry": "Ablaufdatum",
    "Expiry date (optional)": "Ablaufdatum (optional)",
    "Unopened": "Ungeöffnet",
    "Open": "Geöffnet",
    "Expired": "Abgelaufen",
    "Expires today": "Läuft heute ab",
    "Produce": "Obst & Gemüse",
    "Dairy & eggs": "Milchprodukte & Eier",
    "Meat & seafood": "Fleisch & Fisch",
    "Grains & cupboard": "Getreide & Vorrat",
    "Condiments & spices": "Würzmittel & Gewürze",
    "Other": "Sonstiges",
    "Main course": "Hauptgericht",
    "Appetizers": "Vorspeisen",
    "Desserts": "Nachspeisen",
    "Recent": "Neueste",
    "A–Z": "A–Z",
    "Z–A": "Z–A",
    "Instagram": "Instagram",
    "YouTube": "YouTube",
    "TikTok": "TikTok",
    "Link": "Link",
    "Photo": "Foto",
    "Typed in": "Eingetippt",
    "pcs": "Stk.",
    "g": "g",
    "kg": "kg",
    "high": "hoch",
    "medium": "mittel",
    "low": "niedrig",
    "mom's recipes": "Rezepte von Mama",
    "veg": "vegetarisch",
    "non-veg": "nicht vegetarisch",
    "dessert": "Dessert",
    "high protein": "proteinreich",
    "airfryer": "Heißluftfritteuse",
    "Couldn't save": "Speichern fehlgeschlagen",
    "Couldn't delete": "Löschen fehlgeschlagen",
    "Couldn't read that photo": "Foto konnte nicht gelesen werden",
    "Can't load recipes": "Rezepte lassen sich nicht laden",
    "Loading your recipes…": "Rezepte werden geladen…",
    "Reading the recipe…": "Rezept wird gelesen…",
    "No recipes match those filters yet.": "Keine Rezepte passen zu diesen Filtern.",
    "Nothing in your cupboard yet.": "Noch nichts im Vorrat.",
    "Nothing matches that yet.": "Nichts passt dazu.",
    "Your to-buy list is empty.": "Die Einkaufsliste ist leer.",
    "No ingredients selected.": "Keine Zutaten ausgewählt.",
    "No recipes use those ingredients yet.": "Noch keine Rezepte nutzen diese Zutaten.",
    "This recipe is no longer available.": "Dieses Rezept ist nicht mehr verfügbar.",
    "Delete this recipe?": "Dieses Rezept löschen?",
    "This removes it from your box. This can't be undone.": "Es wird aus deiner Sammlung entfernt. Das lässt sich nicht rückgängig machen.",
    "Share a reel from Instagram, paste a link, snap a cookbook page, or write one down yourself.": "Teile ein Reel von Instagram, füge einen Link ein, fotografiere eine Kochbuchseite oder tippe es selbst ein.",
    "Pull to retry. If it keeps failing, open Settings and confirm the server address.": "Zum erneuten Versuch nach unten ziehen. Wenn es weiter scheitert, prüfe in den Einstellungen die Serveradresse.",
    "Shows recipes that use all of these, ranked by fit. Type an ingredient in search to add one.": "Zeigt Rezepte, die all das verwenden, sortiert nach Passung. Tippe in der Suche eine Zutat, um eine hinzuzufügen.",
    "Ignored while ingredient filters are active — closest fit comes first then.": "Wird ignoriert, solange Zutatenfilter aktiv sind — dann zählt zuerst die beste Passung.",
    "Offline — showing recipes saved on this phone": "Offline — Rezepte von diesem iPhone",
    "Could not process that photo.": "Dieses Foto konnte nicht verarbeitet werden.",
    "Something went wrong.": "Etwas ist schiefgelaufen.",
    "Could not reach that server. Check the address and your internet connection.": "Dieser Server ist nicht erreichbar. Prüfe die Adresse und deine Internetverbindung.",
    "The server address is not a valid URL.": "Die Serveradresse ist keine gültige URL.",
    "Saved, but it hasn't shown up in your box yet — pull to refresh in a moment.": "Gespeichert, aber es ist noch nicht in deiner Sammlung — ziehe gleich zum Aktualisieren.",
    "A reel, a video, or any recipe page. We read it and fill the card in for you.": "Ein Reel, ein Video oder eine Rezeptseite. Wir lesen sie und füllen die Karte für dich aus.",
    "Sharing from the app's share sheet still works exactly as before — this is for when the link is already on your clipboard.": "Teilen über das Teilen-Menü funktioniert weiter wie bisher — das hier ist für Links, die schon in der Zwischenablage sind.",
    "Saved to your box": "In deiner Sammlung gespeichert",
    "Check what we read off the page before it goes in the box.": "Prüfe, was wir von der Seite gelesen haben, bevor es in die Sammlung kommt.",
    "one per line": "eine pro Zeile",
    "one per line, in order": "eine pro Zeile, in der richtigen Reihenfolge",
    "one per line as qty | item (blank qty allowed)": "eine pro Zeile als Menge | Zutat (Menge darf leer sein)",
    "Reel, video, or recipe page": "Reel, Video oder Rezeptseite",
    "Cookbook page or recipe card": "Kochbuchseite oder Rezeptkarte",
    "A screenshot you already saved": "Ein Screenshot, den du schon hast",
    "Write it down yourself": "Selbst aufschreiben",
    "Fetching the post": "Beitrag wird geholt",
    "Saving to your box": "Wird in deine Sammlung gespeichert",
    "Page — the text will be read": "Seite — der Text wird gelesen",
    "Instagram reel — caption and owner comment will be read": "Instagram-Reel — Bildunterschrift und Kommentar der Urheberin werden gelesen",
    "Video — audio and description will be read": "Video — Ton und Beschreibung werden gelesen",
    "Gemini reads today": "Gemini-Aufrufe heute",
    "Instagram credit": "Instagram-Guthaben",
    "Toggle grid or list view": "Raster- oder Listenansicht",
    "Add cupboard item": "Artikel hinzufügen",
    "Recipes load from the hosted Stocked server. You do not need your Mac running. Only change this if you are testing a local backend.": "Rezepte kommen vom gehosteten Stocked-Server. Dein Mac muss nicht laufen. Ändere das nur, wenn du ein lokales Backend testest.",
    "Same value as RECIPE_BOX_SECRET on the server — the Shortcut already sends this. Leave blank against a dev server with no secret set.": "Derselbe Wert wie RECIPE_BOX_SECRET auf dem Server — der Kurzbefehl sendet ihn schon. Leer lassen bei einem Entwicklungsserver ohne Schlüssel.",
}

# Format strings: Swift String(localized: "Filtered by \(x)") → key "Filtered by %@"
FORMATS = {
    "Filtered by %@": "Gefiltert nach %@",
    "From %@": "Von %@",
    "Saved %@": "Gespeichert %@",
    "Remove %@": "%@ entfernen",
    "Remove %@ from to-buy list": "%@ von der Einkaufsliste entfernen",
    "Add %@ to to-buy list": "%@ zur Einkaufsliste hinzufügen",
    "Uncheck %@": "Häkchen bei %@ entfernen",
    "Check %@": "%@ abhaken",
    "Quantity for %@": "Menge für %@",
    "+ Add “%@”": "+ „%@“ hinzufügen",
    "Could not reach %@. Check your internet connection, or update the server address in Settings.": "%@ ist nicht erreichbar. Prüfe die Internetverbindung oder die Serveradresse in den Einstellungen.",
    "The server returned HTTP %lld.": "Der Server antwortete mit HTTP %lld.",
    "Resets around %@ CET": "Zurücksetzung gegen %@ MEZ/MESZ",
    "Resets %@": "Zurücksetzung %@",
    "%@ of %@": "%@ von %@",
    "%lld of %lld": "%lld von %lld",
    "Source is set automatically — this one files under **%@** in Filters.": "Die Quelle wird automatisch gesetzt — dieses Rezept erscheint unter **%@** in den Filtern.",
    "Read %lld ingredients and %lld steps. Confidence: %@.": "%lld Zutaten und %lld Schritte gelesen. Sicherheit: %@.",
    "Step %lld of %lld": "Schritt %lld von %lld",
    "Step %lld": "Schritt %lld",
}

PLURALS = {
    "%lld recipes": {
        "en": ("one", "%lld recipe", "other", "%lld recipes"),
        "de": ("one", "%lld Rezept", "other", "%lld Rezepte"),
    },
    "%lld favorites": {
        "en": ("one", "%lld favorite", "other", "%lld favorites"),
        "de": ("one", "%lld Favorit", "other", "%lld Favoriten"),
    },
    "%lld items": {
        "en": ("one", "%lld item", "other", "%lld items"),
        "de": ("one", "%lld Artikel", "other", "%lld Artikel"),
    },
    "%lld to buy": {
        "en": ("one", "%lld to buy", "other", "%lld to buy"),
        "de": ("one", "%lld zum Kaufen", "other", "%lld zum Kaufen"),
    },
    "%lld ingredients": {
        "en": ("one", "%lld ingredient", "other", "%lld ingredients"),
        "de": ("one", "%lld Zutat", "other", "%lld Zutaten"),
    },
    "%lld steps": {
        "en": ("one", "%lld step", "other", "%lld steps"),
        "de": ("one", "%lld Schritt", "other", "%lld Schritte"),
    },
    "Expires in %lld days": {
        "en": ("one", "Expires in %lldd", "other", "Expires in %lldd"),
        "de": ("one", "Läuft in %lld T. ab", "other", "Läuft in %lld T. ab"),
    },
    "%lld of %lld ingredients": {
        "en": ("other", "%lld of %lld ingredients", "other", "%lld of %lld ingredients"),
        "de": ("other", "%lld von %lld Zutaten", "other", "%lld von %lld Zutaten"),
    },
    "%lld selected · matching recipes": {
        "en": ("one", "%lld selected · matching recipes", "other", "%lld selected · matching recipes"),
        "de": ("one", "%lld gewählt · passende Rezepte", "other", "%lld gewählt · passende Rezepte"),
    },
}


def unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def plural_loc(spec: tuple) -> dict:
    # spec is four-tuple unused; we pass dict of lang -> (cat1, val1, cat2, val2)
    raise NotImplementedError


def build() -> dict:
    strings: dict = {}
    for en, de in SIMPLE.items():
        strings[en] = {
            "extractionState": "manual",
            "localizations": {"de": unit(de)},
        }
    for key, de in FORMATS.items():
        strings[key] = {
            "extractionState": "manual",
            "localizations": {"de": unit(de)},
        }
    for key, langs in PLURALS.items():
        locs = {}
        for lang, (c1, v1, c2, v2) in langs.items():
            locs[lang] = {
                "variations": {
                    "plural": {
                        c1: unit(v1),
                        c2: unit(v2),
                    }
                }
            }
        strings[key] = {"extractionState": "manual", "localizations": locs}
    # Fix two-variable plural that used duplicate "other"
    strings["%lld of %lld ingredients"] = {
        "extractionState": "manual",
        "localizations": {
            "en": unit("%lld of %lld ingredients"),
            "de": unit("%lld von %lld Zutaten"),
        },
    }
    strings["%lld selected · matching recipes"] = {
        "extractionState": "manual",
        "localizations": {
            "en": unit("%lld selected · matching recipes"),
            "de": unit("%lld gewählt · passende Rezepte"),
        },
    }
    return {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }


def main() -> None:
    dest = Path(__file__).resolve().parents[1] / "ios" / "RecipeBox" / "Localizable.xcstrings"
    dest.write_text(json.dumps(build(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {dest} ({len(build()['strings'])} keys)")


if __name__ == "__main__":
    main()
