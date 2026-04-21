# Tools/Build — orchestrator core

This folder is the entry point for the orchestrator. For the full story, see the **[top-level README](../../README.md)** and **[docs/CREDENTIALS.md](../../docs/CREDENTIALS.md)**.

| File | Role |
| --- | --- |
| `Build-All.ps1` | Windows entry point. One command, four platforms. |
| `build_mac.sh` | Mac-side runner. Invoked over SSH by `Build-All.ps1`, or manually on the Mac. |
| `upload_play.py` | Google Play Publishing API client (resumable upload, track assignment). |
| `check_play_auth.py` | Non-destructive Play auth smoke test — run this before your first real upload. |
| `config.example.json` | Config template. Copy to `config.local.json` (gitignored) on both machines. |
| `output/` | Unity batchmode logs + JSON reports, organised by entry-point name. Gitignored. |

## Quick commands

```powershell
# Windows — full four-platform run with a patch bump:
.\Build-All.ps1

# Dry run first (prints every command, executes nothing):
.\Build-All.ps1 -DryRun

# Platform subset:
.\Build-All.ps1 -SkipiOS -SkipMacOS         # Windows + Android only
.\Build-All.ps1 -SkipAndroid -SkipiOS       # Windows + macOS only

# Smoke-test Play API auth (before your first Play upload):
python .\check_play_auth.py --service-account <path.json> --package <com.yourcompany.yourgame>
```

## The config file

Copy `config.example.json` to `config.local.json` and fill in real values. Both machines (Windows + Mac) need their own copy; some fields are machine-specific (paths, and the Mac-only `mac.keychainPassword` / `testFlight.*`).

Walk through [docs/CREDENTIALS.md](../../docs/CREDENTIALS.md) in order the first time — every field traces back to a section there.
