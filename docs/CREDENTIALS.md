# Credential gathering — step by step

This is the part that costs a day the first time. Everything below is a **one-time** setup; once it's done, your orchestrator runs unattended.

> If you skip a store, skip that section. You can ship to just one platform and add others later.

---

## Table of contents

1. [SSH: Windows → Mac](#1-ssh-windows--mac)
2. [Mac → GitHub SSH](#2-mac--github-ssh)
3. [macOS Full Disk Access for sshd](#3-macos-full-disk-access-for-sshd)
4. [Mac login keychain password (for headless codesign)](#4-mac-login-keychain-password-for-headless-codesign)
5. [Android — Google Play Store](#5-android--google-play-store)
   - 5a. Keystore
   - 5b. Google Cloud project + service account
   - 5c. Play Console linking + app permission
   - 5d. Enable the Play Android Developer API
   - 5e. Install Python dependencies
   - 5f. First upload: the "draft app" speed bump
6. [iOS — Apple TestFlight](#6-ios--apple-testflight)
   - 6a. Apple Developer Team ID
   - 6b. App Store Connect API key (.p8)
   - 6c. Bundle identifier registration
7. [Steam (Windows + macOS)](#7-steam-windows--macos)
   - 7a. SteamCMD installation
   - 7b. App ID + depot IDs
   - 7c. Branch setup + first login
8. [Final config.local.json walkthrough](#8-final-configlocaljson-walkthrough)

---

## 1. SSH: Windows → Mac

### Enable Remote Login on the Mac

**System Settings → General → Sharing → Remote Login: ON**

Under the toggle you'll see a line like `Local hostname: SinansMacBook.local`. Note it — or use the Mac's LAN IP:

```bash
ipconfig getifaddr en0    # on the Mac
```

### Generate an SSH key on Windows (one-time)

From **PowerShell** on Windows (not elevated):

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519"
```

Press enter through the passphrase prompt (empty passphrase = unattended runs). The key goes to `%USERPROFILE%\.ssh\id_ed25519` + `.pub`.

### Authorize the Windows key on the Mac

From Windows, print the public key:

```powershell
type "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Copy that whole line. On the Mac (via the GUI terminal for now), run:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf '%s\n' 'PASTE_THE_PUBLIC_KEY_LINE_HERE' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Smoke test

From Windows:

```powershell
ssh you@yourmac.local uname -a
```

Expected: a single line starting with `Darwin`. No password prompt.

### Optional: Wake-on-LAN for a sleeping Mac

If your Mac often sleeps between builds (laptops, or desktops with aggressive idle-sleep), the orchestrator can wake it via WoL before it tries SSH. Skip this whole subsection if your Mac stays awake 24/7.

**On the Mac**, enable wake-on-network:

- **System Settings → Energy Saver** (desktop / Mac mini) *or* **Battery → Options** (laptops) → **Wake for network access** → **On** (or **Only on Power Adapter**).
- Plug the Mac into power. Laptops on battery will not honour WoL.

**On Wi-Fi only — disable Private Wi-Fi Address** for this SSID (otherwise macOS randomises the MAC every ~2 weeks and your config silently rots):

- **System Settings → Wi-Fi → (i) next to the connected network → Private Wi-Fi Address → Off**
- The Mac will drop and reconnect with its hardware MAC.

**Find the MAC you'll use** over SSH:

```bash
ifconfig en0 | grep -E 'ether|inet '    # active interface: its MAC + IP
networksetup -getmacaddress Wi-Fi       # hardware MAC (should match after toggling Private off)
```

Use the **active** MAC from `ifconfig` — on Wi-Fi that's what the AP sees. If you toggled Private Wi-Fi Address off above, this now equals the hardware MAC and stays stable forever.

**Fill in the Windows-side config**:

```jsonc
"mac": {
    "sshHost":              "YourMac.local",
    "sshUser":              "you",
    "sshKey":               "~/.ssh/id_ed25519",
    "sshPort":              22,
    "macAddress":           "AA:BB:CC:DD:EE:FF",
    "wolBroadcastAddress":  "192.168.1.255",      // subnet-directed, matches your LAN
    "wolPort":              9,
    "wakeTimeoutSec":       90
}
```

Leave `macAddress` empty to disable WoL; the orchestrator falls through to the regular SSH probe with a one-line warning.

Gotchas (DHCP lease change after MAC toggle, deep-standby Wi-Fi chip power-off, corporate UDP filtering) are covered in [TROUBLESHOOTING § Mac is asleep](TROUBLESHOOTING.md#mac-is-asleep-when-the-build-starts-or-drops-network-mid-run).

---

## 2. Mac → GitHub SSH

Your Mac needs to **pull from your git remote** without a GUI Keychain prompt — SSH sessions don't inherit an unlocked Keychain, so stored HTTPS credentials fail with `Keychain error: -25308`.

On the Mac (over SSH from Windows is fine once step 1 works):

```bash
ssh-keygen -t ed25519 -C "yourname-mac-build-slave"
cat ~/.ssh/id_ed25519.pub
```

Copy the printed line. On GitHub / GitLab: **Settings → SSH and GPG keys → New SSH key** → paste.

Switch your git remote to SSH:

```bash
cd ~/path/to/your-unity-project
git remote set-url origin git@github.com:YOUR_USER/YOUR_REPO.git
git fetch
```

Expected: fetches without prompting.

### If your repo has legacy LFS hooks

Some older projects carry `.git/hooks/post-checkout`, `post-merge`, `post-commit`, `pre-push` that invoke `git-lfs` — but the `.gitattributes` has no `filter=lfs` directive, so the hooks crash an otherwise-clean pull. Disable them:

```bash
cd ~/path/to/your-unity-project/.git/hooks
for h in post-checkout post-merge post-commit pre-push; do
    [ -f "$h" ] && mv "$h" "$h.disabled"
done
```

---

## 3. macOS Full Disk Access for sshd

By default macOS's Transparent Consent & Control (TCC) blocks `sshd` from reading files inside `~/Documents/`, `~/Desktop/`, and `~/Downloads/`. Symptom: your SSH session can `ls` the folder, but any `git` operation inside it returns `Operation not permitted` on files like `.gitignore` or `ProjectSettings.asset`.

**Fix (one-time, on the Mac GUI):**

1. **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, press **⌘⇧G**, paste: `/usr/libexec/sshd-keygen-wrapper`
3. Click **Open**, then **toggle the entry ON**.
4. Log out of SSH and reconnect.

Your Unity project in `~/Documents/GitHub/` is now fully accessible to SSH sessions.

---

## 4. Mac login keychain password (for headless codesign)

When you `xcodebuild archive` over SSH, codesign dies on the first `.framework` signing step with:

```
... errSecInternalComponent
Command CodeSign failed with a nonzero exit code
```

Root cause: the login keychain isn't GUI-unlocked in an SSH session, **and** the signing identity's private key has an ACL partition list that requires user approval for `codesign`. In GUI you'd click "Always Allow"; headless you can't.

**Fix:** let the orchestrator unlock the keychain for you. It needs your Mac login password in the (gitignored) config.

In your Mac's `Tools/Build/config.local.json`, add to the `"mac"` section:

```jsonc
"mac": {
    ...,
    "keychainPassword": "YOUR_MAC_LOGIN_PASSWORD"
}
```

(This is normally the same password you use to unlock the Mac at login. If you changed your login password but not the keychain password, it's whichever one unlocks `Keychain Access.app`.)

The orchestrator runs, before each archive:

```bash
security unlock-keychain -p "$pass" ~/Library/Keychains/login.keychain-db
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" ~/Library/Keychains/login.keychain-db
security set-keychain-settings -t 7200 ~/Library/Keychains/login.keychain-db
```

The `set-key-partition-list` call is idempotent and silent on success.

> **If you never run build_mac.sh over SSH** — e.g., you always run it from a Mac GUI terminal — leave `keychainPassword` empty. The script will warn but continue.

---

## 5. Android — Google Play Store

### 5a. Keystore

If you already have an Android keystore, skip to 5b. Otherwise, in Unity:

**Project Settings → Player → Android → Publishing Settings → Keystore Manager → Keystore → Create New → Anywhere**

Pick a path (a file that lives somewhere in your project, or outside), choose a strong password, create an alias (e.g., `release`) with its own password (or reuse the keystore password).

> **Keep a secure backup of this `.keystore` file.** Lose it and you cannot publish updates to your existing Play app — the app on Play is tied to that specific key. Google offers a "Play App Signing" fallback; read about it before you commit to your signing setup.

In `config.local.json`:

```jsonc
"android": {
    "keystorePath": "relative/path/to/game.keystore",   // relative to project root, or absolute
    "keyaliasName": "release",
    "keystorePassword": "<REDACTED>",
    "keyaliasPassword": ""                               // blank reuses keystorePassword
}
```

### 5b. Google Cloud project + service account

Play uses a Google Cloud **service account** with a JSON private key for API authentication — there's no "Play API key" UI. You create it in Google Cloud and grant it app-level permission in Play Console.

1. Open [console.cloud.google.com](https://console.cloud.google.com).
2. Create a new project (or reuse an existing one) named e.g. `YourGame-publishing`.
3. Go to **IAM & Admin → Service Accounts → + Create Service Account**.
4. Name it e.g. `play-publisher@YourGame-publishing.iam.gserviceaccount.com`. Leave role empty (Play Console grants permissions separately).
5. Click the new service account → **Keys → Add Key → Create new key → JSON → Create**. A `.json` file downloads.
6. **Save that JSON outside your repo.** e.g. `C:\Users\you\.secrets\play_sa.json`. Never commit it.

### 5c. Play Console linking + app permission

1. Go to [play.google.com/console](https://play.google.com/console).
2. **Setup → API access** → **Link a Google Cloud project** → pick the project from step 5b → **Link**.
3. Scroll down; you'll see the service account you created. Click **Grant access**.
4. Permissions page → **App permissions → Add app → choose your game → Apply**.
5. Set **Account permissions** to **Release to production, exclude devices, and use Play App Signing** (or at minimum "Release to testing tracks" + "View app information").
6. **Invite user → Send invitation**.

### 5d. Enable the Play Android Developer API

Even with permissions, Google needs the actual API enabled on your Cloud project.

Open [https://console.developers.google.com/apis/library/androidpublisher.googleapis.com](https://console.developers.google.com/apis/library/androidpublisher.googleapis.com) → select your project → **Enable**. Wait ~60 seconds for it to activate.

### 5e. Install Python dependencies

On Windows:

```powershell
python --version                     # 3.8+
pip install google-auth google-api-python-client
```

### 5f. First upload: the "draft app" speed bump

If your Play app has **never been reviewed** (no release has been promoted out of Internal Testing), Play's API rejects `release.status = "completed"` with:

```
400 Only releases with status draft may be created on draft app.
```

The tool **auto-detects this and retries with `release.status = "draft"`** in the same edit (no re-upload). You'll see:

```
! App is still in draft state on Play Console — Play rejects 'completed' releases until first review.
Retrying commit with release.status='draft' (no re-upload).
Committed DRAFT release: versionCode N on 'internal' track.
MANUAL STEP: Play Console > Testing > Internal testing > Releases > promote the draft to roll out to testers.
```

One-time manual step: in Play Console, open the draft release and **Review release → Start rollout → Confirm**. From your second upload onwards, the orchestrator publishes directly with `status=completed`.

### Fill in config.local.json

```jsonc
"playStore": {
    "serviceAccountJsonPath": "C:\\Users\\you\\.secrets\\play_sa.json",
    "packageName": "com.example.yourgame",
    "track": "internal"
}
```

`track` accepts: `internal`, `alpha`, `beta`, `production`.

### Verify Play auth before your first run

```powershell
python Tools\Build\check_play_auth.py --service-account C:\Users\you\.secrets\play_sa.json --package com.example.yourgame
```

Expected output:

```
service account: play-publisher@yourgame-publishing.iam.gserviceaccount.com
package:         com.example.yourgame
opened edit:     12345...
deleted edit:    ok

RESULT: Play Publishing API auth + app-level permissions OK.
```

Any error here will tell you exactly which link in the chain is missing (401 = JSON key rejected, 403 = service account not invited to the app, 404 = package name unknown, `SERVICE_DISABLED` = step 5d skipped).

---

## 6. iOS — Apple TestFlight

### 6a. Apple Developer Team ID

1. Open [developer.apple.com/account](https://developer.apple.com/account).
2. Scroll to **Membership details**.
3. Copy the **Team ID** — 10 characters, looks like `A1B2C3D4E5`.

### 6b. App Store Connect API key (.p8)

1. Open [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access → Integrations → App Store Connect API → Team Keys**.
2. Click **+**, name the key (e.g. `CI build key`), role **App Manager**, click **Generate**.
3. **Download the `.p8` file immediately** — Apple only lets you download it **once**. If you lose it you have to revoke and create a new key.
4. Record the **Key ID** (10 chars, visible next to the key name).
5. Record the **Issuer ID** (GUID shown at the top of the Keys page).

### Move the .p8 to the Apple-recommended path on the Mac

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
```

### 6c. Bundle identifier registration

Your game's bundle ID (e.g. `com.example.yourgame`) must be registered in Apple's Developer portal:

1. [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers)
2. Click **+ → App IDs → App** → Continue
3. Description = your game name, Bundle ID = Explicit = `com.example.yourgame`
4. Tick the capabilities your game uses (Game Center, Push Notifications, etc.)
5. **Continue → Register**.

You'll also want to create the app shell in App Store Connect before your first TestFlight upload: **appstoreconnect.apple.com → My Apps → + → New App** → select the bundle ID you just registered.

### Fill in config.local.json (on the Mac only — the Windows side never sees these)

```jsonc
"testFlight": {
    "ascApiKeyId": "XXXXXXXXXX",
    "ascApiIssuerId": "69a6de70-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "ascApiKeyP8Path": "/Users/you/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8",
    "teamId": "ABCDE12345",
    "scheme": "Unity-iPhone",
    "exportMethod": "app-store-connect"
}
```

### First TestFlight upload: beta review

Apple's **first ever** upload for a new app triggers a 24-48h beta review. Your subsequent uploads appear in TestFlight within ~10 minutes (processing time).

---

## 7. Steam (Windows + macOS)

### 7a. SteamCMD installation

**Windows:**

```powershell
mkdir C:\steamcmd
cd C:\steamcmd
Invoke-WebRequest https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip -OutFile steamcmd.zip
Expand-Archive steamcmd.zip -DestinationPath .
# First run auto-updates:
.\steamcmd.exe +quit
```

**macOS:**

```bash
mkdir -p ~/Steam && cd ~/Steam
curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz' | tar zxvf -
./steamcmd.sh +quit
```

### 7b. App ID + depot IDs

From the [Steamworks partner dashboard](https://partner.steamgames.com):

1. **Your App → SteamPipe → Depots**
2. You should see at least two depots — one for each OS you ship to. Take their numeric IDs (e.g. App `123456`, Windows depot `123457`, macOS depot `123458`).
3. Under **Steamworks Admin** → Publishing settings confirm each depot's OS is set correctly (`windows` / `macos`).

### 7c. Branch setup + first login

1. **SteamPipe → Builds → Manage Branches** → create a `closed_testing` branch (or reuse an existing one). Set a branch password.
2. **Users and Permissions** → make sure your partner account has "Edit App Metadata" + "Publish App Changes" on this app.
3. First SteamCMD login (Steam Guard 2FA prompt — one time):

```powershell
C:\steamcmd\steamcmd.exe +login your_steam_username
# Type your password, then the Steam Guard code from your phone or email.
# It will say "Login Successful" and cache your session.
+quit
```

Same on the Mac:

```bash
~/Steam/steamcmd.sh +login your_steam_username
# Password, then Steam Guard code
+quit
```

After this, the orchestrator can log in non-interactively for ~30 days before Steam Guard asks again.

### Fill in config.local.json

```jsonc
"steam": {
    "appId": "123456",
    "depotIdWindows": "123457",
    "depotIdMacOS": "123458",
    "username": "your_steam_username",
    "defaultBranch": "closed_testing"
}
```

---

## 8. Final config.local.json walkthrough

Both machines (Windows + Mac) need their own `config.local.json`. Most fields are identical; a few are platform-specific (paths obviously differ).

### Fields on **both** machines

```jsonc
{
    "productName": "YourGame",
    "unity": {
        "version": "6000.3.8f1",
        "windowsEditorPath": "C:\\Program Files\\Unity\\Hub\\Editor\\6000.3.8f1\\Editor\\Unity.exe",
        "macEditorPath": "/Applications/Unity/Hub/Editor/6000.3.8f1/Unity.app/Contents/MacOS/Unity"
    },
    "build": {
        "windowsExeName": "YourGame.exe",
        "macAppName": "YourGame.app",
        "aabName": "YourGame.aab"
    },
    "paths": {
        "winRepoRoot": "D:\\UnityProjects\\YourGame",
        "windowsBuildDir": "D:\\UnityProjects\\YourGameWinBuild",
        "androidBuildDir": "D:\\UnityProjects\\YourGameAndroidBuild",
        "macRepoRoot": "/Users/you/Documents/GitHub/YourGame",
        "macBuildDir": "/Users/you/Documents/YourGameMacOSBuild",
        "iosBuildDir": "/Users/you/Documents/YourGameiOSBuild"
    },
    "android": { /* as above */ },
    "steam":   { /* as above */ },
    "playStore": { /* as above */ }
}
```

### Fields that live on the **Windows** side

```jsonc
"mac": {
    "runMode":              "ssh",
    "sshHost":              "YourMac.local",
    "sshUser":              "you",
    "sshKey":               "~/.ssh/id_ed25519",
    "sshPort":              22,
    // Optional Wake-on-LAN — only the Windows side reads these (see §1 Optional):
    "macAddress":           "",                      // empty disables WoL
    "wolBroadcastAddress":  "192.168.1.255",
    "wolPort":              9,
    "wakeTimeoutSec":       90
}
```

### Fields that live on the **Mac** side

```jsonc
"mac": {
    "keychainPassword": "YOUR_MAC_LOGIN_PASSWORD"      // only the Mac reads this
},
"testFlight": { /* see section 6c */ }
```

> Rule of thumb: if it's a secret that belongs to a machine, keep it on that machine. The Windows PC never needs to know your Mac login password. The Mac never needs to know your Steam 2FA.

---

## You're done

Smoke test:

```powershell
.\Tools\Build\Build-All.ps1 -DryRun
```

This prints every command the orchestrator would run, executes nothing. Verify the paths look correct.

Then:

```powershell
.\Tools\Build\Build-All.ps1 -SkipStoreUploads
```

This produces local artefacts for all four platforms without uploading. If this succeeds, you know every build path works; now try a real upload with `.\Tools\Build\Build-All.ps1`.

If anything went wrong, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
