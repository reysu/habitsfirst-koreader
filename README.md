# habitsfirst-koreader

KOReader plugin that syncs your daily pages read to the **Habits First** app, so reading can count toward your habits and unlock your blocked apps.

## Install

1. Copy the `habitsfirst.koplugin/` folder into `koreader/plugins/` on your reader (USB, or however you move files onto it).
2. In Habits First: **More integrations → KOReader → Plugin → Connect** — the app shows a token like `hf_…`.
3. On the reader, create `koreader/settings/habitsfirst.lua`:

   ```lua
   return { token = "hf_...", channel = "koreader", window = 21 }
   ```

4. Restart KOReader. Done.

## What it does

KOReader already records every page you turn in its own statistics database. This plugin reads that database and sends your pages-per-day (last 21 days, only days that changed) to your Habits First inbox over WiFi — a few hundred bytes, tied to your token, visible only to you.

It syncs by itself: shortly after KOReader starts, after you close a book, on suspend, and whenever WiFi reconnects (rate-limited to once per 5 minutes). Reading offline is fine — days backfill the next time the reader touches WiFi. Manual sync: **Tools → Habits First sync → Sync now**, which also shows the last result.

Every network call is wrapped in `pcall` — a sync failure can never interrupt reading.

## Privacy

The plugin sends: date, pages turned, minutes read, and book titles (so the app can show "35 pages — Book title"). Nothing else leaves the device. Rows are stored keyed by your random token; without the token they are unreadable.
