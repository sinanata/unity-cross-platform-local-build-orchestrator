# Unity cross-platform local build orchestrator

One PowerShell command on your Windows PC builds and ships your Unity game to **four platforms** — Windows (Steam), Android (Google Play), iOS (TestFlight), and macOS (Steam) — using a Mac on the same LAN over SSH. Open-sourced as part of a small giving-back set of Unity tools — alongside the [UI Toolkit design system](https://github.com/sinanata/unity-ui-document-design-system) and the [Voronoi mesh fracturer](https://github.com/sinanata/unity-mesh-fracture).

<blockquote>
<a href="https://store.steampowered.com/app/2269500/"><img src="docs/leap-of-legends-icon.png" align="left" width="70" height="70" alt="Leap of Legends"></a>
Built for <strong><a href="https://leapoflegends.com">Leap of Legends</a></strong> — a cross-platform multiplayer game in active development, using this orchestrator weekly to cut builds to Steam, Google Play internal testing, and TestFlight. <a href="https://store.steampowered.com/app/2269500/">Wishlist on Steam</a> — public mobile store pages coming soon.
</blockquote>

---

```
========================================================================
  Leap of Legends build orchestrator
========================================================================
  [OK]   Config loaded
  [OK]   Unity: C:\Program Files\Unity\Hub\Editor\6000.3.8f1\Editor\Unity.exe
  [OK]   Keystore
  [OK]   SteamCMD present
  [OK]   Python + Play credentials present
  [OK]   D: has 2603 GB free
  [OK]   Mac reachable: Darwin 15.6

  Version bump:      patch
  Steam branch:      closed_testing
  Android:           build + Play internal
  Windows:           build + Steam [closed_testing]
  iOS:               build append + TestFlight
  macOS:             build + Steam [closed_testing]

  [/]   Android  total 02:34  |  Building Gradle project [00:45]
  [OK]   AAB: ...\YourGameAndroidBuild\YourGame.aab  (116.8 MB)
  Upload progress: 17% 34% 51% 68% 85%
  [OK]   Play Store: uploaded to 'internal' track.

  [\]   Windows  total 03:12  |  Incremental Player Build [01:08]
  [OK]   Windows build  (277.9 MB)
  [OK]   Steam (Windows) upload complete.

  [OK]   Committed + pushed: build 0.1.51 (code 52)

  [|]   iOS archive  total 05:14  |  compiling 688/1110 (62%)
  [OK]   iOS archive done
  [OK]   iOS export done
  [OK]   TestFlight: uploaded YourGame.ipa
  [OK]   macOS .app  (312.4 MB)
  [OK]   Steam (macOS) upload complete.

========================================================================
  All done in 23 min 14 sec
========================================================================
```

---

## Why this exists

Shipping a cross-platform Unity game means repeating a ~10-step ritual every release: bump version, build Windows, build Android, upload AAB, build macOS on the Mac, build iOS on the Mac, archive in Xcode, upload to TestFlight, upload macOS to Steam, commit, push. One missed step and your platforms diverge.

This tool does the whole ritual with **one command**, in parallel where possible, with defensive preflight checks so you catch a missing keystore or an unreachable Mac **before** you wait 15 minutes for IL2CPP to finish.

It's deliberately **local** — no CI/CD, no cloud runners, no paid minutes, no opaque build logs in someone else's UI. Your Unity editor, your Mac, your LAN, your terminal.

## What it does

1. **Preflight** — validates Unity, keystore, SteamCMD, Python, SSH reachability, disk space.
2. **Bump version** — `bundleVersion` +patch, `AndroidBundleVersionCode` +1, iOS/macOS build numbers synced.
3. **Android AAB** → uploaded to Google Play Internal Testing via the Play Publishing API (service account).
4. **Windows build** → uploaded to Steam via SteamCMD (branch configurable).
5. **Git commit + push** of the version bump.
6. **SSH into the Mac** → git hard-reset → `build_mac.sh`:
   - **iOS build** (append mode preserves your Xcode project customisations) → `xcodebuild archive` → `xcrun altool --upload-app` to TestFlight.
   - **macOS build** (universal x64 + arm64) → uploaded to Steam via SteamCMD.
7. **Summary** — every artefact path, upload status, total time.

All output is **colour-coded and progress-animated** — real phase names from Unity's `DisplayProgressbar:` markers and IL2CPP's `[N/M elapsed]` compile counter, not an indeterminate hourglass.

## Requirements

### Windows PC

| Requirement | Notes |
| --- | --- |
| Unity with **Android** + **Windows Standalone** modules | Unity Hub → Installs → your version → Add Modules |
| PowerShell 5.1+ | Ships with Windows 10/11 |
| [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) | Default path: `C:\steamcmd\steamcmd.exe` (configurable) |
| Python 3.8+ | Only needed for Play Store upload |
| `pip install google-auth google-api-python-client` | Only needed for Play Store upload |
| OpenSSH client | Built into Windows 10/11 (`Settings → Apps → Optional features → OpenSSH Client`) |
| `git` | In `PATH` |

### Mac (for iOS + macOS builds)

| Requirement | Notes |
| --- | --- |
| Unity with **iOS** + **macOS Standalone** modules | Same version as Windows |
| Xcode + command-line tools | `xcode-select --install` |
| Apple Developer Account signed in to Xcode | Preferences → Accounts |
| [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) | Default path: `~/Steam/steamcmd` |
| `jq` | `brew install jq` |
| **Remote Login: ON** | System Settings → General → Sharing → Remote Login |
| Same git repo cloned | Must contain this orchestrator + your Unity project |

### First-time project requirements

- Your Unity project is a **git repo** that both machines can clone (GitHub, GitLab, self-hosted — whatever).
- You have publisher accounts for the stores you want to ship to (Steam partner, Google Play developer, Apple Developer Program). Each is a paid membership with its own setup — see [docs/CREDENTIALS.md](docs/CREDENTIALS.md) for the step-by-step.

## Installation

The orchestrator files live in two folders plus one Unity Editor script:

```
your-unity-project/
├── Assets/
│   └── Editor/
│       └── BuildCli.cs                 ← drop in
├── Tools/
│   ├── Build/                          ← drop in
│   │   ├── Build-All.ps1
│   │   ├── build_mac.sh
│   │   ├── upload_play.py
│   │   ├── check_play_auth.py
│   │   └── config.example.json
│   └── Steam/                          ← drop in
│       ├── deploy.ps1
│       └── deploy_mac.sh
└── .gitignore                          ← add the entries from this repo's .gitignore
```

**Option A — copy files into your project:**

```powershell
# From your Unity project root, on Windows:
git clone https://github.com/sinanata/unity-cross-platform-local-build-orchestrator ..\orchestrator-src
xcopy /E /I ..\orchestrator-src\Assets\Editor\BuildCli.cs Assets\Editor\
xcopy /E /I ..\orchestrator-src\Tools Tools\
Copy-Item ..\orchestrator-src\.gitignore .gitignore_orchestrator  # review and merge
```

**Option B — git submodule (recommended if you plan to pull updates):**

```bash
cd your-unity-project
git submodule add https://github.com/sinanata/unity-cross-platform-local-build-orchestrator Tools/.orchestrator
# Then symlink or copy the pieces into place; submodule keeps them versioned.
```

Commit + push so the Mac can pull the same layout.

## Quick start

After installation and credential gathering (see below):

```powershell
# From your Unity project root
Copy-Item Tools\Build\config.example.json Tools\Build\config.local.json
notepad Tools\Build\config.local.json        # fill in values — see CREDENTIALS.md

# Same on the Mac (from your Mac terminal):
cp Tools/Build/config.example.json Tools/Build/config.local.json
# edit with your preferred editor

# First run:
.\Tools\Build\Build-All.ps1 -Bump patch
```

The orchestrator will walk you through any preflight failures before it starts the slow work.

## Credential gathering

This is the part that costs a day the first time. **[Full step-by-step in docs/CREDENTIALS.md](docs/CREDENTIALS.md)** — covers:

- **Android keystore** (Unity → Keystore Manager → where the password goes in config)
- **Google Play service account JSON** (Cloud Console → Play Console linking → app-level permission → .json download → `pip install` → first upload limitation)
- **Apple App Store Connect API key** (.p8 download, Issuer ID, Key ID, Team ID, path on Mac)
- **Steam partner account + SteamCMD** (first-time Steam Guard dance, branch setup, depot layout)
- **Mac headless codesign** (login keychain password, why xcodebuild fails with `errSecInternalComponent` over SSH and how to fix it)
- **SSH key-based auth** (Windows → Mac, Mac → your git remote, macOS TCC / Full Disk Access for sshd)

## Daily usage

```powershell
# Patch-bump and ship everything to closed testing
.\Tools\Build\Build-All.ps1

# Minor-bump with a description shown in Steam + TestFlight
.\Tools\Build\Build-All.ps1 -Bump minor -Description "Endless mode + cosmetics"

# Quick Windows+Android hotfix (skip Mac entirely)
.\Tools\Build\Build-All.ps1 -SkipiOS -SkipMacOS

# Dry run — see every command, execute nothing
.\Tools\Build\Build-All.ps1 -DryRun

# Build everything but don't upload (local QA pass)
.\Tools\Build\Build-All.ps1 -SkipStoreUploads

# Ship to Steam's public 'default' branch for a release
.\Tools\Build\Build-All.ps1 -Branch default -Description "v0.2.0"

# Re-upload current version without bumping (e.g. after a VDF tweak)
.\Tools\Build\Build-All.ps1 -SkipVersionBump
```

### All flags

```
-Bump              none | patch | minor | major     (default: patch)
-Branch            Steam branch                      (default: closed_testing)
-Description       "Free-form build note"            (applied to Steam + Play release notes)
-SkipAndroid       Skip Android build + Play upload
-SkipWindows       Skip Windows build + Steam upload
-SkipiOS           Skip iOS build + TestFlight upload
-SkipMacOS         Skip macOS build + Steam upload
-SkipStoreUploads  Keep artefacts local; upload nothing
-SkipVersionBump   Reuse current version
-SkipCommit        Don't git-commit the bump
-SkipPush          Don't git-push (Mac will fail to pull — use only for local tests)
-DryRun            Print every command; execute nothing
-Yes               Skip the initial confirmation prompt
-ClearCache        Nuke Library/BurstCache + Bee + ScriptAssemblies + Temp
                   before building (full reimport). Use to recover from
                   stale-cache issues like NetCode RPC wire-format desyncs.
                   Persistent alternative: unity.clearCacheBeforeBuild=true
                   in config.local.json.
-ConfigPath path   Use an alternate config.*.json
```

## What makes this robust

Every run verifies these **before** touching Unity:

- Config parses as JSON; all required fields present.
- Unity editor path exists on Windows (and on Mac inside `build_mac.sh`).
- Keystore file exists; password + alias are set.
- SteamCMD is installed when Steam upload is planned.
- Python + Play JSON are present when Play upload is planned.
- 10+ GB free on the build drive (warning below that threshold).
- Mac reachable with a 6-second SSH probe. Fails fast with a fix-checklist if Remote Login isn't on yet.
- **Sleeping Mac auto-wake** — if the preflight TCP probe times out, the orchestrator sends a Wake-on-LAN magic packet to `mac.macAddress` and polls SSH until it responds (configurable timeout). Once the build starts on the Mac, `caffeinate -dims -w $$` keeps it awake for the full run and exits with the shell. Works on Wi-Fi with a couple of caveats — see [TROUBLESHOOTING.md § Mac is asleep](docs/TROUBLESHOOTING.md#mac-is-asleep-when-the-build-starts-or-drops-network-mid-run).
- `BuildCli.cs` writes a JSON report after every Unity step; orchestrator aborts if `success != true`.
- `Clean-Dir` refuses to delete a path shorter than 8 characters or a bare drive root — protects you from a typo like `windowsBuildDir: "D:\"`.
- Android keystore password is wiped from in-memory `PlayerSettings` after the AAB build so it can never leak into `ProjectSettings.asset`.
- **Mac is a pure build slave** — the SSH step does `git fetch && git reset --hard @{u} && git clean -fd` on the Mac before building, so a stray Unity-touched file can never block a pull.

## Architecture

```
┌────────────────────────────────────────────┐
│ Windows PC                                 │
│ ┌────────────────────────────────────────┐ │
│ │  Tools/Build/Build-All.ps1             │ │
│ │   • preflight + confirmation           │ │
│ │   • Unity -batchmode (Android, Win)    │ │
│ │   • upload_play.py                     │ │
│ │   • Tools/Steam/deploy.ps1             │ │
│ │   • git commit + push                  │ │
│ └────────────────────┬───────────────────┘ │
└──────────────────────┼─────────────────────┘
                       │ ssh -t
                       ▼
┌────────────────────────────────────────────┐
│ MacBook                                    │
│ ┌────────────────────────────────────────┐ │
│ │  Tools/Build/build_mac.sh              │ │
│ │   • git reset --hard origin            │ │
│ │   • Unity -batchmode (iOS, OSXUniv.)   │ │
│ │   • security unlock-keychain           │ │
│ │   • xcodebuild archive + exportArchive │ │
│ │   • xcrun altool --upload-app          │ │
│ │   • Tools/Steam/deploy_mac.sh          │ │
│ └────────────────────────────────────────┘ │
└────────────────────────────────────────────┘
```

**`Tools/Build/Build-All.ps1`** — the Windows entry point and single source of truth. Reads `config.local.json`, runs preflight, drives Unity, pushes to stores, SSHes into the Mac.

**`Tools/Build/build_mac.sh`** — the Mac-side twin. Invoked only over SSH by the orchestrator (or manually if you prefer). Reads the Mac's copy of `config.local.json`.

**`Assets/Editor/BuildCli.cs`** — Unity batchmode entry points. Exposes `BuildOrchestrator.Cli.BuildCli.{Windows, MacOS, iOS, Android, BumpVersion, PrintVersion}`. Reads scenes from Unity's `EditorBuildSettings`, so whatever you configured in **File → Build Settings** is what ships.

**`Tools/Build/upload_play.py`** — Google Play Publishing API v3 client. Resumable upload, configurable track, auto-falls-back to `status=draft` if the app is in draft state (fresh apps reject `status=completed` until their first review).

**`Tools/Steam/deploy.ps1` / `deploy_mac.sh`** — SteamCMD wrappers. VDFs generated on the fly from the app/depot IDs in your config, so no committed files contain your Steam app ID.

## Troubleshooting

See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. Covers:

- SSH probe fails
- macOS SSH can't read `~/Documents` (TCC / Full Disk Access)
- xcodebuild `errSecInternalComponent`
- Play API 401 / 403 / `SERVICE_DISABLED`
- "App is in draft state" on first Play upload
- Unity "license already in use" / batchmode collisions
- Steam Guard prompting every run
- Mac `git pull` rejecting modified/untracked files

## Security

- `Tools/Build/config.local.json` contains your keystore password, Mac login password, Steam username. **Never commit it** (gitignored already).
- Store the Play service account JSON and Apple `.p8` **outside** the repo. Paths in config point to external locations.
- The orchestrator never logs the values of `-cliKeystorePass`, `-cliKeyaliasPass`, or `keychainPassword`.
- `BuildCli.cs` wipes `PlayerSettings.Android.keystorePass` / `keyaliasPass` in a `finally` block so even a crashing build can't leave the password in `ProjectSettings.asset`.
- All SSH traffic is key-based — no passwords sent over the wire.

## Contributing

Issues and PRs welcome. The tool is intentionally small (~1500 lines total across PowerShell, bash, Python, and C#) — readable in an afternoon, hackable in a weekend.

If you run into a store API quirk this tool doesn't handle, the fix usually lives in one of:

- `upload_play.py` — Play Publishing API
- `build_mac.sh` — xcodebuild + altool + codesign
- `Tools/Steam/*` — SteamCMD + VDF generation

## Credits & support

Made for **[Leap of Legends](https://leapoflegends.com)** — a cross-platform physics-heavy multiplayer game in active development, targeting Steam, iOS, Android, and Mac. If this tool saved you time:

- ⭐ Star the repo
- 🎮 [Wishlist Leap of Legends on Steam](https://store.steampowered.com/app/2269500/) — mobile store pages coming soon
- 🐦 Shout out [@sinanata](https://x.com/sinanata)

## Licence

MIT — see [LICENSE](LICENSE). Free for commercial use. No warranty.

---

**[Leap of Legends](https://leapoflegends.com)** · physics · multiplayer · cross-platform · in development · built weekly with this tool.
