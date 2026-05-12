# Troubleshooting

Failures, their symptoms, and their fixes — in the order you're most likely to hit them.

---

## Preflight

### `SSH probe failed`

- Turn **Remote Login** on in Mac System Settings → General → Sharing.
- From a Windows shell: `ssh you@yourmac.local uname` — what does it say?
  - `Permission denied (publickey)` → Windows public key isn't in the Mac's `~/.ssh/authorized_keys`. Redo [CREDENTIALS § 1](CREDENTIALS.md#1-ssh-windows--mac).
  - `Host key verification failed` → delete the offending line in `%USERPROFILE%\.ssh\known_hosts`, run once manually to accept the new fingerprint.
  - Hostname doesn't resolve → use the LAN IP (`ipconfig getifaddr en0` on the Mac).
- If SSH succeeds from Windows but the orchestrator still fails the probe, check `ssh -v you@yourmac.local uname` for a clue.

### `Unity editor not found at ...`

Your `unity.windowsEditorPath` (or `unity.macEditorPath`) doesn't match where Unity is actually installed. Common traps:

- Unity Hub installs each version in its own folder — check `C:\Program Files\Unity\Hub\Editor\<version>\Editor\Unity.exe`.
- If Unity is in a custom location (e.g. on a different drive), point the config at it directly.

### `SteamCMD not found at C:\steamcmd\steamcmd.exe`

Either install SteamCMD to `C:\steamcmd` ([official installer](https://developer.valvesoftware.com/wiki/SteamCMD)) or skip Steam uploads with `-SkipStoreUploads`.

### `Python 3 not found in PATH`

Either install Python 3.8+ and `pip install google-auth google-api-python-client`, or leave `playStore.serviceAccountJsonPath` empty in config (Play upload will be skipped).

---

## Mac / SSH

### Mac is asleep when the build starts (or drops network mid-run)

A sleeping Mac fails every downstream step: the preflight SSH probe times out, `.local` hostnames may not resolve (Bonjour is off during deep sleep), and disk/network syscalls can stall for several seconds just after wake. The orchestrator handles this by:

1. **TCP-probing** `sshPort` on the Mac before anything else (2s timeout).
2. If no response, **sending a Wake-on-LAN magic packet** to `mac.macAddress` via UDP to `mac.wolBroadcastAddress:mac.wolPort`.
3. **Polling SSH** every 3s for up to `mac.wakeTimeoutSec` seconds (default 90).
4. Once `build_mac.sh` starts, it spawns `caffeinate -dims -w $$` to keep the Mac awake for the full build. Caffeinate exits automatically when the shell does (success, error, or Ctrl+C).

> **Good to know**: macOS's "Wake for network access" wakes on *any* incoming TCP SYN to a listening port, not just magic packets. So even if magic-packet delivery is flaky on your LAN, the orchestrator's initial 2-second TCP probe itself tends to wake the Mac. The WoL path is primarily insurance for when the TCP probe times out (deep sleep / standby, slow hardware wake, or broken Wi-Fi WoL).

**To enable Wake-on-LAN:**

1. Find the active interface and its MAC. SSH in and run:
   ```bash
   ifconfig en0 | grep -E 'ether|inet '   # active MAC + IP of en0
   networksetup -getmacaddress Wi-Fi      # hardware MAC for Wi-Fi
   ```
   Use the **MAC from `ifconfig`** — that's what's actually on the wire. On Wi-Fi, the AP only associates + delivers broadcast frames to *that* MAC.

2. macOS: **System Settings → Energy Saver** (desktop / Mac mini) *or* **Battery → Options** (laptops) → **Wake for network access** → **On** (or **Only on Power Adapter** for laptops).

3. Plug the Mac into power. Laptops on battery will not honour WoL, full stop.

4. Add the fields to `config.local.json` on the Windows side:
   ```jsonc
   "mac": {
       "sshHost":              "YourMac.local",     // or LAN IP
       "sshUser":              "you",
       "macAddress":           "AA:BB:CC:DD:EE:FF",
       "wolBroadcastAddress":  "192.168.1.255",      // subnet-directed; see below
       "wolPort":              9,
       "wakeTimeoutSec":       90,
       ...
   }
   ```

Leaving `macAddress` empty disables WoL entirely — the tool prints a one-line warning and falls through to the real SSH probe.

---

### Wi-Fi trap: Private Wi-Fi Address randomises the MAC (macOS 14+)

Since macOS Sonoma (14), each Wi-Fi network has a **Private Wi-Fi Address** setting that's on by default. It presents a randomised locally-administered MAC to the AP instead of the burnt-in hardware MAC, and rotates it every ~2 weeks or on SSID reconnect. Wi-Fi WoL with this on means your `macAddress` config entry works today and silently breaks next rotation.

**How to tell which MAC you're seeing:**

```bash
ifconfig en0 | awk '/ether/ {print $2}'    # currently on the wire
networksetup -getmacaddress Wi-Fi          # burnt-in hardware MAC
```

If the two differ, Private Wi-Fi Address is active. Quick visual check: if bit 1 of the first octet is set (e.g. `0xA6 = 10100110` → bit 1 is 1), it's locally administered (randomised). A burnt-in MAC usually has that bit clear (e.g. `0x74 = 01110100`).

**Three ways to live with this:**

- **Track the rotating MAC.** Every time WoL breaks, SSH in, re-read `ifconfig en0`, update config. Works, but surprises you every couple of weeks.
- **Disable Private Wi-Fi Address for this SSID.** *(Recommended for a build host.)* On the Mac: **System Settings → Wi-Fi → (i) next to the connected network → Private Wi-Fi Address → Off**. The Mac drops and reconnects using its hardware MAC; from then on `ifconfig en0` and `networksetup -getmacaddress Wi-Fi` match and stay matched. There's no CLI equivalent on macOS 15.6 — `networksetup -setPrivateWiFiAddressMode` does not exist.
- **Switch to Ethernet.** Private Wi-Fi Address doesn't apply to Ethernet. `ifconfig en3` (or whichever Ethernet adapter), read its MAC, plug it into the LAN, use that interface's IP and MAC. Ethernet WoL is also more reliable across deep-sleep / standby than Wi-Fi WoL regardless of Private MAC.

**After toggling Private Wi-Fi Address, your Mac's IP may change.** DHCP treats the new MAC as a new client and assigns a fresh lease. Either set a **DHCP reservation** for the hardware MAC in your router, give the Mac a static IP, or update `mac.sshHost` to the new IP after confirming with `ifconfig en0 | grep 'inet '`.

---

### WoL fires but the Mac doesn't wake

**Limited broadcast didn't get forwarded.** `wolBroadcastAddress: "255.255.255.255"` is the *limited* broadcast; most consumer routers accept it on the same LAN but drop it at VLAN / subnet boundaries. If Windows and Mac are on the same LAN but your router is strict, use a **subnet-directed** broadcast matching the Mac's subnet — e.g. `"192.168.1.255"`.

**Windows outbound firewall / VPN.** Corporate outbound rules sometimes block UDP 9. Try `"wolPort": 7`, or temporarily allow the outbound rule. If you have a VPN or Hyper-V virtual switch consuming the default route, WoL traffic may leave on the wrong interface — disable the virtual adapter and retry.

**Mac is in deep standby.** macOS transitions from regular sleep to **standby** after a few hours (default ~3 hours on AC), where the Wi-Fi chip is powered off entirely. At that point no magic packet can reach the Wi-Fi radio; only a keypress, a USB event, or Ethernet WoL can wake it. Mitigations:

```bash
sudo pmset -c standby 0       # AC: never go into standby (keeps Wi-Fi chip alive, tiny AC draw)
```

or just use Ethernet — the PHY stays powered regardless of standby mode, and Ethernet WoL works from any sleep depth.

**Mac wakes but slower than 90 s.** Raise `wakeTimeoutSec` to 180 for a Mac mini on a slow SSD after deep sleep. Long delays before port-open usually mean sshd is disabled or Remote Login got turned off — `sudo launchctl list | grep ssh` should show `com.openssh.sshd`.

---

### Mac sleeps too eagerly (every build starts against a sleeping Mac)

Check `pmset -g`:

```
AC Power:
 sleep                1      ← aggressive: sleeps after 1 min of idle
 displaysleep         60
 standby              1
```

Raise the idle-to-sleep timeout on AC:

```bash
sudo pmset -c sleep 60        # sleep after 60 min idle on AC (or 0 = never)
```

This is a quality-of-life fix, not a WoL fix — the orchestrator can still wake a sleeping Mac. But fewer wake cycles mean faster builds overall and less chance of hitting deep standby.

### `Operation not permitted` when the SSH session reads files in `~/Documents`

macOS TCC is blocking `sshd` from reading protected directories.

**Fix:** System Settings → Privacy & Security → Full Disk Access → **+** → press **⌘⇧G** → paste `/usr/libexec/sshd-keygen-wrapper` → **Open** → toggle ON. Reconnect SSH.

See [CREDENTIALS § 3](CREDENTIALS.md#3-macos-full-disk-access-for-sshd).

### `Keychain error: -25308` when Mac tries to `git pull`

SSH sessions don't inherit a GUI-unlocked Keychain, so git's HTTPS credential-helper fails. Switch the Mac's git remote to SSH:

```bash
cd ~/path/to/your-unity-project
git remote set-url origin git@github.com:YOUR_USER/YOUR_REPO.git
git fetch
```

(See [CREDENTIALS § 2](CREDENTIALS.md#2-mac--github-ssh).)

### Legacy LFS hooks abort the pull

If your repo has `git-lfs` hooks left over from an earlier setup but `.gitattributes` no longer declares `filter=lfs`, post-checkout/post-merge/pre-push hooks will exit non-zero and cancel the merge.

Disable them on the Mac:

```bash
cd ~/path/to/your-unity-project/.git/hooks
for h in post-checkout post-merge post-commit pre-push; do
    [ -f "$h" ] && mv "$h" "$h.disabled"
done
```

### Mac `git pull` fails with "local changes would be overwritten"

The orchestrator's default SSH command is `git fetch && git reset --hard '@{u}' && git clean -fd`. That's intentional — **the Mac is a pure build slave**, and any stray modifications (Unity touching `ProjectSettings.asset`, dropped `.meta` files, etc.) get wiped on every run.

If you want to debug what changed, SSH in manually before a run:

```bash
cd ~/path/to/your-unity-project
git status
git fetch --all
git log --oneline HEAD..origin/yourbranch
```

---

## Unity build

### Unity `license already in use` / batchmode refuses to start

Close the Unity Editor GUI. Unity's license checkout is exclusive — a live editor session and a batchmode invocation fight for the same seat and one of them loses.

### `PrintVersion failed (exit 1)` immediately, no progress at all

The project is locked by a leftover `Temp\UnityLockfile` from a previous run that died without cleaning up — Ctrl+C, PowerShell window killed via Task Manager, BSOD, or **Unity itself crashing in native code** (see next entry). With the lockfile present, every Unity batchmode invocation against the project exits ~1 second after start with code 1.

The current `Build-All.ps1` does three things to prevent and recover from this:

1. **Preflight scrub** — checks for a stale `Temp\UnityLockfile` at startup and removes it if no live Unity has it locked.
2. **Outer `try/finally`** — kills the tracked Unity process tree on Ctrl+C / `throw`.
3. **Always-on lockfile cleanup** — `Stop-AllTrackedUnity` removes `Temp\UnityLockfile` *unconditionally* in the finally, including the case where Unity died on its own (native crash) and there were no tracked PIDs left to kill.

If you're on an older copy of the orchestrator (before the always-on cleanup was added), or if the PowerShell process itself was killed before the finally could run, clean up manually:

```powershell
Get-Process Unity -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item 'PATH\TO\YourProject\Temp\UnityLockfile' -Force -ErrorAction SilentlyContinue
```

Then re-run. If `Get-Process Unity` returns nothing but the lockfile still exists, just delete the lockfile.

`build_mac.sh` has the same protection — a `trap abort_cleanup INT TERM HUP` walks the descendant process tree (Unity, `AssetImportWorker`, `xcodebuild`, `clang`, `altool`, `steamcmd`) on SIGINT (Ctrl+C via `ssh -t`), SIGHUP (SSH drop), or SIGTERM, and removes `Temp/UnityLockfile`. If a Windows BSOD / power loss prevents the trap from firing, the Mac sshd will detect the dead connection via TCP keepalive (default ~2 hours) and send SIGHUP then. Until then, clean up manually on the Mac:

```bash
pkill -f Unity.app
pkill -f xcodebuild
rm -f /path/to/your-project/Temp/UnityLockfile
```

### Unity crashed in native code (exit `-1073741819` or similar large negative)

Exit codes like `-1073741819`, `-1073741571`, `-1073740940`, `-1073740791` are signed-decimal renderings of Windows NTSTATUS exception codes — `0xC0000005` (access violation), `0xC00000FD` (stack overflow), `0xC0000374` (heap corruption), `0xC0000409` (stack-buffer-overrun / GS-cookie), respectively. They mean Unity itself crashed in native code, not that your build emitted an error. The Unity log usually has no managed stack trace because the fault was below the C# layer; you'll see a `Crash!!!` line followed by a long DLL list and no resolved frames.

Recent versions of `Build-All.ps1` decode these codes into a human-readable label and dump a recovery checklist. Older copies just report the raw integer.

**Where to find the crash dump:**

```
%TEMP%\Unity\Editor\Crashes\Crash_<TIMESTAMP>\crash.dmp
```

That directory is timestamped per-crash; the most recent folder is what you want. Open `crash.dmp` in WinDbg (`!analyze -v`) for a real stack trace, or attach it to a Unity bug report.

**Recovery, in order:**

1. **Re-run with `-ClearCache`** — most native crashes during script compile / asset reload are stale-cache desyncs (Burst AOT, Bee, ScriptAssemblies, Temp). The flag nukes those four directories before the next Unity invocation. Adds ~5–15 min for the full reimport.

   ```powershell
   .\Tools\Build\Build-All.ps1 -ClearCache
   ```

2. **Confirm `Temp\UnityLockfile` is gone** — the orchestrator's preflight scrub handles this on subsequent runs, but if you're on an older copy, delete it manually (see the previous entry).

3. **If the crash repeats with cleared caches**, you've got a real Unity bug. Open the editor GUI once (any project), then **Help → Report a Bug** and attach the `crash.dmp` + the Unity log path the orchestrator printed. As a workaround, drop to the previous Editor patch version (Unity Hub → Installs → Add → pick the prior `f1`); native crashes that are version-specific usually get fixed in the next patch.

4. **Project-specific suspects worth checking** when the crash reproduces deterministically:

   - **Custom native plugins** — a freshly added `.dll` in `Assets/Plugins/x86_64` can crash the editor on first import if its dependencies don't resolve. Move it out of the project, run, then move it back.
   - **Asset corruption** — a single broken asset can crash during reimport. `git status` for recently-added binaries; remove and reimport one by one.
   - **Mismatched plugin manifest vs `current-build/` folder** in EDM4U-style packages (Google Play Games, Firebase, AdMob). Their on-startup `VersionHandler` / `Upgrader` runs every editor launch and has historically taken down whole Editor sessions. If the crash sits right after a `*Upgrader done` log line, that family of plugins is the prime suspect — try deleting the plugin's `current-build/` folder + the EDM4U cache (`Library/PackageCache/com.google.external-dependency-manager*`) and reimporting.

### `Keystore file not found: ...\game.keystore`

`android.keystorePath` is resolved relative to the project root if not absolute. Either:

- Put the `.keystore` file at the path you specified, or
- Set an absolute path: `"keystorePath": "C:\\keys\\mygame.keystore"`.

### `Android key alias 'release' not found in keystore`

A keystore can hold multiple aliases. List them:

```powershell
keytool -list -keystore your.keystore
# Enter keystore password
```

Pick the alias that matches the SHA-256 fingerprint your Play Console shows under **Setup → App integrity → App signing**.

### `"success": false` in the Unity report

The orchestrator aborts with "reported failure: <message>". Open the referenced Unity log file (path is in the error line). The real failure is usually an IL2CPP error, a missing Android SDK component, or a compile-error in your code that the editor tolerates but batchmode doesn't.

### NetCode `RpcSystem failed to deserialize RPC ... bits read X did not match expected Y`

Stale Burst AOT cache. Server and client live in the same build — even the same process — but different native compilations of the same C# type got cached: one agrees with the old wire format, one with the new. Commonly triggered by inserting (rather than appending) a field in an `IRpcCommand` struct.

**Fix:** re-run with `-ClearCache` (Windows) / `--clear-cache` (Mac). The orchestrator nukes `Library/BurstCache`, `Library/Bee`, `Library/ScriptAssemblies`, and `Temp` before the next Unity invocation, forcing a full regeneration.

```powershell
.\Tools\Build\Build-All.ps1 -ClearCache
```

Or set `unity.clearCacheBeforeBuild: true` in `config.local.json` to keep it on by default. Full reimport adds ~5-15 min.

Prevention: always **append** new fields to `IRpcCommand` structs; never insert in the middle. The wire layout is positional.

---

## Play Store

### `HTTP 401` / `JSON key rejected`

The service account JSON is invalid. Regenerate it in Google Cloud Console → Service Accounts → your account → Keys → Add Key → JSON.

### `HTTP 403` / `The caller does not have permission`

Auth works, but the service account doesn't have permission on **this app**. Check:

1. Play Console → Setup → API access — is your Cloud project linked?
2. Play Console → Users and permissions — is your service account email listed?
3. Click the service account → App permissions — is your app checked with "Release to testing tracks" (or higher)?

### `HTTP 403` / `SERVICE_DISABLED`

The Play Android Developer API isn't enabled on your Cloud project. Visit:

https://console.developers.google.com/apis/library/androidpublisher.googleapis.com

Select your project → **Enable**. Wait ~60s.

### `HTTP 404` / package unknown

Your `playStore.packageName` doesn't match any app in Play Console. Check for typos (`com.example.yourgame` is case-sensitive).

### `400 Only releases with status draft may be created on draft app.`

Your app is in Play's "draft" state (no release has been reviewed yet). The tool auto-falls-back to uploading as a **draft** release; you then manually promote it once in Play Console. See [CREDENTIALS § 5f](CREDENTIALS.md#5f-first-upload-the-draft-app-speed-bump).

### `400 Changes cannot be sent for review automatically. Please set the query parameter changesNotSentForReview to true.`

Play won't auto-submit this edit because the app has pending **metadata changes that require manual review** — commonly the content rating questionnaire, data-safety form, target-audience / Families declaration, or app-access instructions. This is separate from the bundle upload: the binary is fine, but Play wants a human to look at the metadata first.

The tool auto-falls-back by retrying the commit with `changesNotSentForReview=true`, so the binary still uploads and the release is queued. You then finish it manually:

**Play Console → Publishing overview → "Send N changes for review"** (button in the yellow banner).

Once that batch is approved, subsequent uploads go back to auto-submitting. Expect to hit this once after any Families / data-safety / content-rating edit, then never again until the next metadata change.

### Upload says success but Play Console shows nothing

Check **Release → Testing → Internal testing → Track history** (may take ~60s to appear). If the API reported a `versionCode`, the upload succeeded — it may just be in a different track than you're viewing.

---

## TestFlight

### `xcodebuild archive` fails with `errSecInternalComponent` on a framework

Classic headless-codesign failure. Add your Mac login password to `config.local.json`:

```jsonc
"mac": {
    ...,
    "keychainPassword": "YOUR_MAC_LOGIN_PASSWORD"
}
```

See [CREDENTIALS § 4](CREDENTIALS.md#4-mac-login-keychain-password-for-headless-codesign).

### `No matching provisioning profile`

- `testFlight.teamId` must be the 10-char Team ID, not your Apple ID email. Find it at [developer.apple.com/account → Membership details](https://developer.apple.com/account).
- Your bundle ID must be registered at [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers).
- The ASC API key must have role **App Manager**, not **Developer**.
- Xcode must have signed in to your Apple Developer account at least once (GUI). `-allowProvisioningUpdates` needs that to auto-mint profiles.

### `altool` uploads, but TestFlight says "build is processing" forever

Apple's first-ever upload for a new app triggers a 24-48h beta review. After that, builds appear in TestFlight in ~10 minutes. If it's been 2+ hours on a subsequent upload, check the email Apple sent (look for "Your app has one or more issues" warnings).

### iOS build missing capabilities

Unity rewrites your Xcode project on every iOS build. If you customise the project (Swift/ObjC files, entitlements, capabilities), use `BuildOptions.AcceptExternalModificationsToPlayer` — which this tool does by default in "append mode" (`-cliIosAppend true`). Unity merges its changes into your existing project instead of wiping it.

---

## Steam

### Steam Guard prompts every run

SteamCMD caches credentials per-machine for ~30 days, after which it re-prompts. If it's every run:

- Check `%USERPROFILE%\config.vdf` on Windows or `~/Steam/config/config.vdf` on Mac — if the cached session is corrupt, delete it and log in once manually (`C:\steamcmd\steamcmd.exe +login your_user`).
- If you have Steam Guard Mobile Authenticator with shared-secret extraction, you can wire it into `deploy.ps1`; that's out of scope here.

### `FAILED (Invalid Password)`

Your Steam partner account was logged out. `steamcmd +login your_user` manually once; type password + 2FA code when prompted.

### `Tried to build appid N, was not found in any accessible appmanifests`

The Steam user account in config doesn't have build-upload permission on this app. Steamworks partner dashboard → Users and Permissions → your user → **Edit App Metadata** + **Publish App Changes**.

### VDF errors like `expected '{'`

The tool generates VDFs at runtime from your config. If you see a VDF parse error, check that `steam.appId`, `steam.depotIdWindows`, `steam.depotIdMacOS` are numeric strings (e.g. `"123456"`, not `"game123456"`).

### macOS Steam upload hangs ~10 minutes then `Build for depot X failed`

`steamcmd` hit `HTTP 401` while pre-fetching the previous depot's manifest from Valve's content CDN and silently retried (a `.` every ~11s in `~/Library/Application Support/Steam/logs/console_log.txt`) until it gave up. Almost always a stale entry in `~/Library/Application Support/Steam/depotcache/` referencing a manifest the CDN no longer serves under the current session's token.

`deploy_mac.sh` detects this case automatically: on `Failed to download manifest ... (HTTP 401)` it clears `depotcache` and retries once. It also enforces a wall-clock timeout (env `STEAM_TIMEOUT_SEC`, default 1800s) so a stuck `steamcmd` can't block the orchestrator longer than 30 min. The full transcript is captured to `Tools/Steam/output/steamcmd_mac_*.log` for diagnosis (the auto-retry variant is `*.retry.log`).

If both attempts still fail, clear depotcache manually and re-run the macOS-only path:

```bash
rm -rf "$HOME/Library/Application Support/Steam/depotcache"
ssh youruser@yourmac '~/.../Tools/Build/build_mac.sh --skip-ios'
```

### `xcodebuild` / `altool` left `log stream` processes running after build

macOS's `xcodebuild` and `xcrun altool` spawn `log stream --predicate ... subsystem == "com.apple.network"` helpers for their own network diagnostics. They re-parent to `launchd` the moment the spawning tool exits, so a naive descendant walk in `build_mac.sh`'s `abort_cleanup` missed them. The current tool reaps them by predicate signature both on normal exit and abort. If you find stragglers anyway, `pkill -f 'log stream --predicate process contains "(Xcode|altool)" and subsystem == "com.apple.network"'`.

---

## General

### The orchestrator reports "exit " (empty) and claims failure

This was a PowerShell 5.1 bug with `Start-Process -PassThru`: the returned Process handle was auto-disposed before ExitCode could be read. The current tool pins the handle with `$null = $proc.Handle` and falls back to reading the success flag from the Unity report JSON. If you still see this message, update to the latest `Build-All.ps1`.

### Progress line doesn't update during Mac Unity / xcodebuild steps

Bash's builtin `printf` is stdio-line-buffered on a tty — CR-only updates queue until the next newline. The tool uses external `/usr/bin/printf` via a `render_progress` helper so updates flush. If progress is still silent, check that your SSH invocation uses `-t` (forces a pty); the tool does by default.

### xcodebuild output still floods the terminal despite the progress wrapper

The wrapper redirects full xcodebuild output to `Tools/Build/output/xcodebuild-*.log` on the Mac. The progress line only shows the IL2CPP `[N/M]` counter + phase hints. If you're seeing raw compile commands in-place, your `build_mac.sh` is out of date — re-sync from this repo and redeploy.

### "I just want to see the Unity log"

Every Unity invocation writes its full log to `Tools/Build/output/unity-<entry>-<timestamp>.log` on the machine that ran Unity (Windows for Win/Android, Mac for iOS/macOS). The orchestrator prints the path before each build.

---

## Getting more help

- Check the log files in `Tools/Build/output/` on both machines — they're verbose enough to diagnose almost anything.
- `-DryRun` prints every command the orchestrator would execute without actually running them. Great for spotting path/config typos.
- When filing a GitHub issue, include: OS versions (Win + macOS), Unity version, the relevant log file's last ~200 lines, and the exact command you ran.
