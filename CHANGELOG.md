# Changelog

All notable changes to this project will be documented here.

This project loosely follows [Semantic Versioning](https://semver.org/) and uses the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

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
