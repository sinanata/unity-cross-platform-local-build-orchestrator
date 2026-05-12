# Changelog

All notable changes to this project will be documented here.

This project loosely follows [Semantic Versioning](https://semver.org/) and uses the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [1.2.1] — 2026-05-12

### Added

- **Steam macOS upload watchdog + HTTP-401 auto-retry.** `deploy_mac.sh` wraps the `steamcmd` invocation in a wall-clock watchdog (`STEAM_TIMEOUT_SEC`, default 1800s) and a 401-aware retry. Why: steamcmd has no internal upload timeout — on `HTTP 401` from Valve's content CDN during the depot manifest pre-fetch, it prints a `.` every ~11s and silently retries forever until something else kills it. Observed in the wild as a `build_mac.sh` blocked for ~10 minutes before steamcmd gave up on its own, with no actionable signal in stdout. The 401 itself is recoverable: it's almost always a stale entry in `~/Library/Application Support/Steam/depotcache/` referencing a manifest the CDN no longer serves under the current session's CDN token. `run_steamcmd_once` tees the transcript to `Tools/Steam/output/steamcmd_mac_*.log`; on failure, `is_manifest_401_failure` greps for `Failed to download manifest ... (HTTP 401)` and, if matched, calls `clear_depotcache` and re-runs once (`*.retry.log`). The watchdog uses `pkill -P $$ -f steamcmd` so it only reaps descendants of the deploy script — never an unrelated Steam client the user might have open on the GUI.

### Fixed

- **`xcodebuild` / `xcrun altool` `log stream` orphans now reaped.** Both tools spawn `log stream --predicate process contains "(Xcode|altool)" and subsystem == "com.apple.network"` helpers for their own network diagnostics. The helpers re-parent to `launchd` (PPID=1) the moment the spawning tool exits, so `_list_descendants $$` in `abort_cleanup` missed them — they'd accumulate across builds, harmless but ugly. Added `reap_apple_network_log_orphans` (predicate-specific `pkill`, idempotent) called from both the normal-exit tail of `build_mac.sh` and from `abort_cleanup`.

## [1.2.0] — 2026-04-30

### Added

- **Pre-build UXML/USS validation in `BuildCli.cs`.** Before every player build, `ValidateUiAssets()` enumerates every `*.uxml` / `*.uss` under `Assets/`, force-reimports each with `ImportAssetOptions.ForceUpdate | ForceSynchronousImport`, and captures any `LogType.Error` / `Exception` / `Assert` lines that fire during the import via `Application.logMessageReceived`. If any file's import logs an error or returns a null asset, the build aborts with a per-file failure list. UI Toolkit's importer reports XML well-formedness errors, unknown elements, attribute parse failures and USS syntax errors via `Debug.LogError`, but does *not* mark the player build as failed — without this step, a malformed UXML happily ships and surfaces as a runtime "Failed to clone" or a blank screen. Adds a few seconds; catches the entire class of bug at the only step before the upload starts. No-op for projects that don't use UI Toolkit.
- **Burst-AOT cache-corruption auto-retry.** `Build-All.ps1` (`Test-BurstCacheFailure` + `Clear-BurstCacheOnly` + `Invoke-Unity-OrDie` retry) and `build_mac.sh` (`test_burst_cache_failure` + `clear_burst_cache_only` + `run_unity` wrapper) now scan a failed Unity build's log for the `BuildFailedException: Burst compiler (...) failed running` signature. When matched, the orchestrator scrubs `Library/BurstCache` plus the Bee-side Burst job artifacts (`Library/Bee/Burst*`, `Library/Bee/artifacts/*PlayerBuildProgram/AsyncPluginsFromLinker*`) and re-runs Unity *once* before propagating failure. The bcl exit-3 / empty-stderr signature is narrow enough that genuine `[BurstCompile]` errors (which carry actual stderr content) don't auto-retry. Native crashes still flow through the existing native-crash diagnostic path. Replaces the previous "re-run with `-ClearCache`" manual step for what's by far the most common transient failure.

### Fixed

- **`deploy_mac.sh` exit-code capture under `set -e`.** `EXIT_CODE=$?` after the `steamcmd` invocation was dead code: with `set -euo pipefail` the script aborts at the failing command and the troubleshooting branch never runs. Switched to `cmd || EXIT_CODE=$?` so SteamCMD failures still produce diagnostics. Added a 42-specific hint when the bare-binary fallback gets used (Valve's self-update relaunch protocol — `MAGIC_RESTART_EXITCODE=42` from the wrapper script).
- **`upload_play.py` resumable-upload retry on transient network errors.** A single read timeout near the end of a 128 MB AAB upload killed the whole transfer with no retry — the script's only loop just called `req.next_chunk()` and surfaced the first transient socket exception as a fatal exit 3. New `_next_chunk_with_retry` wraps each chunk in up to 6 attempts with exponential backoff (2s → 60s capped) for `socket.timeout`, `ConnectionError`, `ssl.SSLError`, `httplib2.HttpLib2Error`, and HTTP 5xx/429. Resumable uploads keep server-side state, so a retry just continues from the last committed byte. Also reduced default chunk size 20 MB → 8 MB (every chunk now fits comfortably inside the timeout) and bumped the process socket timeout 60s → 300s.

## [1.1.1] — 2026-04-25

### Fixed

- **`Stop-AllTrackedUnity` now scrubs `Temp\UnityLockfile` unconditionally.** The previous implementation early-returned when no Unity PIDs were tracked — but `Run-Unity` always unregisters its own PID in its inner finally, so by the time the outer cleanup runs the list is empty, and the lockfile cleanup at the bottom of the function never executed. Net effect: Unity native crashes (`-1073741819` access violation etc.) left a stale `Temp\UnityLockfile` behind that blocked every subsequent build with `PrintVersion failed (exit 1) immediately, no progress at all`. The fix splits the function into a conditional "kill tracked PIDs" path and an unconditional `Remove-StaleUnityLockfile` call, plus a preflight call to recover from any pre-existing stale lockfiles left by older orchestrator versions or hard reboots.

### Added

- **Native-crash exit-code decoding.** `Invoke-Unity-OrDie` now maps known NTSTATUS exception codes (`-1073741819`, `-1073741571`, `-1073740940`, `-1073740791`, `-1073741795`, …) to their human-readable labels (`STATUS_ACCESS_VIOLATION`, `STATUS_STACK_OVERFLOW`, `STATUS_HEAP_CORRUPTION`, `STATUS_STACK_BUFFER_OVERRUN`, `STATUS_ILLEGAL_INSTRUCTION`, …) and prints a recovery checklist with the path to `%TEMP%\Unity\Editor\Crashes\` and a pointer to the `-ClearCache` flag, so users don't have to look up the crash code manually.
- **TROUBLESHOOTING.md § "Unity crashed in native code"** — full recovery flow including where to find `crash.dmp`, when to use `-ClearCache`, and project-specific suspects for the EDM4U `VersionHandler` family.

### Known tool quirks worked around

- PowerShell here-string interpolation: `"$Label:"` is parsed as a *scoped* variable reference (`$Label:Whatever`), not as the variable `$Label` followed by a colon. Use `"${Label}:"` to delimit the variable name. Cost: one syntax-check round while writing the native-crash diagnostic message.

## [1.1.0] — 2026-04-24

### Added

- **Wake-on-LAN pre-SSH wake.** If the preflight TCP probe times out, the Windows orchestrator sends a magic packet to `mac.macAddress` (broadcast to `mac.wolBroadcastAddress:mac.wolPort`, both configurable) and polls the SSH port every 3 s up to `mac.wakeTimeoutSec` (default 90). No-op when the Mac is already reachable or when `macAddress` is unset — gracefully falls through to the existing SSH probe for users who don't need WoL.
- **`caffeinate -dims -w $$` in `build_mac.sh`.** Keeps the Mac awake for the full build and exits when the shell does. Prevents idle/disk/system sleep from stalling a long headless Unity + xcodebuild run. Auto-reaped by the existing `abort_cleanup` descendant-walker on Ctrl+C or SSH drop.
- **Ctrl+C cleanup on both sides.** Windows `Build-All.ps1` wraps the full flow in `try/finally`, tracks every spawned Unity PID, and on interrupt walks the descendant tree (Unity + `AssetImportWorker` children) and removes `Temp\UnityLockfile`. `build_mac.sh` has a `trap abort_cleanup INT TERM HUP` that does the same on the Mac side (Unity, `xcodebuild`, `clang`, IL2CPP, `altool`'s java subprocess, `steamcmd`). Eliminates the "`PrintVersion failed (exit 1)` immediately" symptom after a cancelled build.
- **Play Store auto-fallback for `changesNotSentForReview`.** When Play rejects a commit with `HTTP 400 "Changes cannot be sent for review automatically"` (triggered by pending metadata changes from Families / content-rating / data-safety edits), the tool retries the commit with `changesNotSentForReview=true` so the binary still uploads. Prints a one-time "Send N changes for review" pointer to Play Console's Publishing overview.
- **`mac.macAddress` + three sibling fields in `config.example.json`** with an explanatory comment about finding the MAC, enabling "Wake for network access", and the macOS 14+ Private Wi-Fi Address trap.
- **TROUBLESHOOTING.md § Mac is asleep** — full walkthrough: enabling WoL, the Private Wi-Fi Address randomisation trap on macOS 14+, DHCP reservation after disabling it, the `sleep 1` aggressive-default mitigation, and deep-standby / Wi-Fi chip power-off caveats.

### Known tool quirks worked around

- Em-dashes (`—`) inside PowerShell double-quoted strings break parsing on PS 5.1. The engine reads `.ps1` files with the system ANSI codepage (CP-1252), and the 3-byte UTF-8 `0xE2 0x80 0x94` sequence reinterprets into characters that derail quote-matching — the parser then reports `Missing '}'` far from the actual problem. Keep `.ps1` strings ASCII-only; em-dashes in `#` comments are harmless.
- PS 5.1 `ConvertFrom-Json` returns `$null` for missing properties — every new `mac.*` field reads safely with `[string]$Config.mac.whatever ?? ''` semantics without enabling strict-mode breakage.

## [1.0.0] — 2026-04-21

Initial open-source release, extracted from the in-development build pipeline of **[Leap of Legends](https://leapoflegends.com)**.

### Added

- **`Tools/Build/Build-All.ps1`** — Windows entry point. End-to-end four-platform build + upload in one command.
- **`Tools/Build/build_mac.sh`** — Mac-side runner invoked over SSH by the Windows orchestrator.
- **`Assets/Editor/BuildCli.cs`** — Unity batchmode entry points (`BuildOrchestrator.Cli.BuildCli.{Windows, MacOS, iOS, Android, BumpVersion, PrintVersion}`).
- **`Tools/Build/upload_play.py`** — Google Play Publishing API v3 client with resumable upload, track assignment, and auto-fallback to `status=draft` for fresh apps.
- **`Tools/Build/check_play_auth.py`** — non-destructive Play auth smoke test.
- **`Tools/Steam/deploy.ps1`** + **`deploy_mac.sh`** — parameterised SteamCMD wrappers that generate VDFs on the fly.
- **Colour-coded, progress-animated output** — real phase names from Unity's `DisplayProgressbar:` markers and IL2CPP's `[N/M elapsed]` compile counter, not an indeterminate spinner.
- **Defensive preflight** — config parsing, Unity editor, keystore, SteamCMD, Python, disk space, SSH reachability.
- **Mac headless codesign support** — `security unlock-keychain` + `set-key-partition-list` before `xcodebuild archive`, solving the classic `errSecInternalComponent` over SSH.
- **Docs**: `docs/CREDENTIALS.md` (step-by-step credential gathering) + `docs/TROUBLESHOOTING.md`.

### Known tool quirks worked around

- PS 5.1 `Start-Process -PassThru` drops the Process handle on exit — the tool pins it with `$null = $proc.Handle` so `ExitCode` stays readable.
- Bash builtin `printf` line-buffers on a tty, so `\r` progress updates queued invisibly over SSH — the tool calls external `/usr/bin/printf` which flushes per-invocation.
- `xcodebuild archive` is thousands-of-lines verbose by default — output is redirected to a log file, with a single-line progress indicator visible and the last 60 lines dumped on failure.
- Mac is treated as a pure build slave: `git fetch && git reset --hard '@{u}' && git clean -fd` on every run, so stray Unity-touched files never block a pull.
- Fresh Play apps reject `release.status="completed"` with a 400 error until their first manual review — the tool auto-retries with `status="draft"` and prints a one-time manual-promotion hint.
