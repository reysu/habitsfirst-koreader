# habitdesu-koreader

KOReader plugin that syncs daily pages read to habitdesu (log-habit webhook).
Install: copy habitdesu.koplugin/ to koreader/plugins/, put token+habit in koreader/settings/habitdesu.lua.
Deployed on Boox Palma via adb.

## Habits First (iOS)

Same plugin, different token. In Habits First: More integrations → Shortcuts →
Other devices → Create a device token (`hf_…`). Then `settings/habitdesu.lua`:

    return { token = "hf_...", channel = "read", window = 21 }

Pages per day land in the `read` channel; a habit (Insights → Habits, filled in
by Shortcut, channel `read`) or a block condition on that channel uses them.
Backend: `supabase/` in the screentimedesu-ios repo (table + `hf-report` function).
