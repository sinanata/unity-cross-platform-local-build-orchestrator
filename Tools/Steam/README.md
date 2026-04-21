# Tools/Steam — SteamCMD wrappers

Two thin wrappers around SteamCMD that generate VDF files on the fly from the app/depot IDs you pass in. No committed VDFs means no committed secrets.

| File | Platform |
| --- | --- |
| `deploy.ps1` | Windows builds (PowerShell) |
| `deploy_mac.sh` | macOS builds (bash) |

## Normal usage

You don't usually call these directly — **`Tools/Build/Build-All.ps1`** (Windows) and **`Tools/Build/build_mac.sh`** (Mac) do it for you with values pulled from `config.local.json`.

## Manual usage (one-off upload)

### Windows

```powershell
.\deploy.ps1 -Username mysteamuser `
             -AppId 123456 -DepotId 123457 `
             -ContentRoot D:\Builds\YourGameWinBuild `
             -ProductName YourGame `
             -Branch closed_testing
```

### macOS

```bash
./deploy_mac.sh -u mysteamuser \
                -a 123456 -D 123458 \
                -c ~/Documents/YourGameMacOSBuild \
                -n YourGame \
                -b closed_testing
```

## Steamworks one-time setup

Before your first deploy, make sure these exist in the [Steamworks partner dashboard](https://partner.steamgames.com):

1. **App** — your App ID exists and has a product page (doesn't need to be public).
2. **Depots** — SteamPipe → Depots. Create one depot per OS you ship to. Take note of the numeric IDs.
   - Typically: one for Windows, one for macOS.
   - In the depot's settings, set the correct **OS** (`windows` / `macos`) so Steam installs the right depot per user platform.
3. **Branches** — SteamPipe → Builds → Manage Branches. Create a `closed_testing` branch (or reuse an existing one) and set a password for closed beta testers.
4. **Launch options** — configure per-OS launch options so Steam runs the right binary on each platform.
5. **Permissions** — your partner account needs **Edit App Metadata** + **Publish App Changes**. Check under Users and Permissions.

## Excluded from uploads

The generated depot VDF excludes these patterns — they're Unity artefacts that shouldn't ship:

- `*.pdb` — Windows debug symbols
- `*.log` — log files
- `*_BurstDebugInformation_DoNotShip*` — Unity Burst debug data
- `*_BackUpThisFolder_ButDontShipItWithYourGame*` — Unity crash handler backup

If you need to customise exclusions, edit the depot-VDF heredoc at the top of each deploy script.

## Steam Guard / 2FA

First SteamCMD login on each machine will prompt for your Steam Guard code (email or Mobile Authenticator). After that, credentials are cached in `%USERPROFILE%\config.vdf` (Windows) or `~/Steam/config/config.vdf` (macOS) for ~30 days.

If auth starts breaking every run, delete the cached `config.vdf` and log in once manually.
