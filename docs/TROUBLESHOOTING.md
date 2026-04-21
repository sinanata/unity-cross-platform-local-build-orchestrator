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
