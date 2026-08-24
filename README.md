# habitdesu-koreader

KOReader plugin that syncs daily pages read to habitdesu (log-habit webhook).
Install: copy habitdesu.koplugin/ to koreader/plugins/, put token+habit in koreader/settings/habitdesu.lua.
Deployed on Boox Palma via adb.

## Habits First (iOS)

Same plugin, different token. In Habits First: More integrations → Shortcuts →
Other devices → Create a device token (`hf_…`). Then `settings/habitdesu.lua`:

    return { token = "hf_...", channel = "koreader", window = 21 }

Pages per day land in the KOReader integration (More integrations → KOReader,
Plugin mode): a "Pages read" block condition or a habit filled in by KOReader.
Backend: `supabase/hf_reports.sql` in the screentimedesu-ios repo (one paste;
PostgREST upsert with the anon key + `x-hf-token` header, RLS-scoped).
