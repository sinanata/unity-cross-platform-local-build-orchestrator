#!/bin/bash
# Mac-side build runner. Invoked over SSH from Tools/Build/Build-All.ps1
# (or manually on the Mac). Builds iOS (append) and macOS via Unity batchmode,
# optionally archives + uploads to TestFlight, then runs Tools/Steam/deploy_mac.sh
# for the Steam macOS depot.
#
# Configuration comes from:
#   - Environment variables (preferred, set by the Windows orchestrator):
#       BRANCH, DESCRIPTION, SKIP_IOS, SKIP_MACOS, SKIP_UPLOADS, DRY_RUN
#   - Tools/Build/config.local.json  (paths, Unity, TestFlight, keychain, steam)
#
# Paired with:
#   - Assets/Editor/BuildCli.cs
#   - Tools/Build/Build-All.ps1
#   - Tools/Steam/deploy_mac.sh
#
# https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
# Originally built for https://leapoflegends.com

set -euo pipefail

# Give SSH logins the same PATH the GUI shell would have.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.local.json"
OUTPUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUTPUT_DIR"

# Unity batchmode entry-point class (matches BuildCli.cs namespace).
UNITY_CLASS="BuildOrchestrator.Cli.BuildCli"

# ---------- Defaults, overridden by env + CLI flags ----------
BRANCH="${BRANCH:-closed_testing}"
DESCRIPTION="${DESCRIPTION:-}"
SKIP_IOS="${SKIP_IOS:-false}"
SKIP_MACOS="${SKIP_MACOS:-false}"
SKIP_UPLOADS="${SKIP_UPLOADS:-false}"
DRY_RUN="${DRY_RUN:-false}"
# No default — empty means "fall back to config.unity.clearCacheBeforeBuild below".
CLEAR_CACHE="${CLEAR_CACHE-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-ios)      SKIP_IOS=true;       shift ;;
        --skip-macos)    SKIP_MACOS=true;     shift ;;
        --skip-uploads)  SKIP_UPLOADS=true;   shift ;;
        --dry-run)       DRY_RUN=true;        shift ;;
        --clear-cache)   CLEAR_CACHE=true;    shift ;;
        --branch)        BRANCH="$2";         shift 2 ;;
        --description)   DESCRIPTION="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--skip-ios] [--skip-macos] [--skip-uploads] [--dry-run] [--clear-cache] [--branch X] [--description X]"
            echo "Env: BRANCH, DESCRIPTION, SKIP_IOS, SKIP_MACOS, SKIP_UPLOADS, DRY_RUN, CLEAR_CACHE"
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---------- UI helpers ----------
# ANSI colors only when writing to a terminal (ssh -t pty counts).
if [ -t 1 ]; then
    C_CYAN=$'\e[36m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_RED=$'\e[31m'
    C_GRAY=$'\e[90m'
    C_RESET=$'\e[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; C_RESET=""
fi
bar="========================================================================"
section() { printf "\n%s%s\n  %s\n%s%s\n" "$C_CYAN" "$bar" "$1" "$bar" "$C_RESET"; }
step()    { printf "\n%s--- %s ---%s\n" "$C_YELLOW" "$1" "$C_RESET"; }
ok()      { printf "%s  [OK]   %s%s\n"  "$C_GREEN"  "$1" "$C_RESET"; }
warn()    { printf "%s  [WARN] %s%s\n"  "$C_YELLOW" "$1" "$C_RESET" >&2; }
info()    { printf "%s  [..]   %s%s\n"  "$C_GRAY"   "$1" "$C_RESET"; }
fail()    { printf "%s  [FAIL] %s%s\n"  "$C_RED"    "$1" "$C_RESET" >&2; exit 1; }
skip()    { printf "%s  [SKIP] %s%s\n"  "$C_GRAY"   "$1" "$C_RESET"; }
run()     {
    info "$*"
    if [ "$DRY_RUN" != "true" ]; then
        "$@"
    fi
}
cfg()     { jq -r "$1" "$CONFIG_FILE"; }

clean_dir() {
    if [ -z "$1" ] || [ "${#1}" -lt 8 ]; then fail "Refusing to clean suspicious path '$1'"; fi
    if [ -d "$1" ]; then
        info "Cleaning $1"
        if [ "$DRY_RUN" != "true" ]; then rm -rf "$1"; fi
    fi
    if [ "$DRY_RUN" != "true" ]; then mkdir -p "$1"; fi
}

# Nuke Unity's Burst AOT + Bee + assembly caches so the next Unity invocation
# regenerates everything from scratch. Recovery tool for stale-cache issues
# like NetCode "RpcSystem failed to deserialize RPC ... bits read X did not
# match expected Y" where server+client disagree on wire format within one
# process. Expensive (full reimport, +5-15 min) but deterministic.
clear_unity_cache() {
    local dirs=(
        "$REPO_ROOT/Library/BurstCache"
        "$REPO_ROOT/Library/Bee"
        "$REPO_ROOT/Library/ScriptAssemblies"
        "$REPO_ROOT/Temp"
    )
    step "Clearing Unity caches ($REPO_ROOT)"
    warn "Next Unity run will do a full reimport."
    for d in "${dirs[@]}"; do
        if [ -d "$d" ]; then
            info "Removing $d"
            if [ "$DRY_RUN" != "true" ]; then rm -rf "$d"; fi
        fi
    done
}

# Print a single-line in-place progress update. bash's BUILTIN printf uses
# stdio which is line-buffered for a tty, so naive `printf "\r..."` is queued
# until the next newline — over SSH, that means progress is invisible until
# later loud output floods in. Using the EXTERNAL /usr/bin/printf forks a
# short-lived child whose stdio buffer is flushed on exit.
render_progress() {
    /usr/bin/printf "\r%-120s" "$1"
}
clear_progress_line() {
    /usr/bin/printf "\r%-120s\r" ""
}

# Poll the Unity log while the editor runs and render a single-line live
# progress display driven by 'DisplayProgressbar:' markers.
wait_unity_with_progress() {
    local unity="$1"
    local log_file="$2"
    local label="$3"
    shift 3

    # Unity writes its own log via -logFile, so hiding its sparse stdout keeps
    # our \r-driven progress line clean.
    "$unity" "$@" >/dev/null 2>&1 &
    local pid=$!

    local start phase phase_start
    start=$(date +%s)
    phase="starting..."
    phase_start=$start
    local spin=(\| / - \\)
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1

        if [ -f "$log_file" ]; then
            local last_line
            last_line="$(tail -n 200 "$log_file" 2>/dev/null | grep -E '^DisplayProgress(bar|Notification):' | tail -n 1 || true)"
            if [ -n "$last_line" ]; then
                local new_phase="${last_line#*: }"
                if [ "$new_phase" != "$phase" ]; then
                    phase="$new_phase"
                    phase_start=$(date +%s)
                fi
            fi
        fi

        local now elapsed phase_el em es pm ps s shown line
        now=$(date +%s)
        elapsed=$((now - start))
        phase_el=$((now - phase_start))
        em=$((elapsed / 60)); es=$((elapsed % 60))
        pm=$((phase_el / 60)); ps=$((phase_el % 60))
        s="${spin[i % 4]}"; i=$((i + 1))

        shown="$phase"
        if [ ${#shown} -gt 60 ]; then
            shown="${shown:0:57}..."
        fi

        line=$(printf "  [%s]   %s  total %02d:%02d  |  %s [%02d:%02d]" \
                      "$s" "$label" "$em" "$es" "$shown" "$pm" "$ps")
        render_progress "$line"
    done

    wait "$pid"
    local ec=$?
    clear_progress_line
    return $ec
}

# Poll an xcodebuild log file and render progress based on the
# `[  NNN/MMMM  Xs] C_iOS_arm64 ...` lines Unity's IL2CPP build driver emits
# during archive. Falls back to Xcode phase names (CompileC, Ld, CodeSign ...)
# once IL2CPP is done.
wait_xcode_with_progress() {
    local pid="$1"
    local log_file="$2"
    local label="$3"

    local start now elapsed em es
    start=$(date +%s)
    local spin=(\| / - \\)
    local i=0
    local status="starting..."

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1

        if [ -f "$log_file" ]; then
            local il2cpp_line xcode_phase
            il2cpp_line="$(tail -n 400 "$log_file" 2>/dev/null | grep -E '^\[[[:space:]]*[0-9]+/[0-9]+' | tail -n 1 || true)"
            if [ -n "$il2cpp_line" ]; then
                local n m pct
                n="$(printf '%s' "$il2cpp_line" | sed -E 's/^\[[[:space:]]*([0-9]+)\/([0-9]+).*/\1/')"
                m="$(printf '%s' "$il2cpp_line" | sed -E 's/^\[[[:space:]]*([0-9]+)\/([0-9]+).*/\2/')"
                if [ -n "$n" ] && [ -n "$m" ] && [ "$m" -gt 0 ]; then
                    pct=$((100 * n / m))
                    status="compiling $n/$m ($pct%)"
                fi
            else
                xcode_phase="$(tail -n 200 "$log_file" 2>/dev/null | grep -Eo '^(CompileC|CompileSwift|Ld|CodeSign|Copy|GenerateDSYMFile|ProcessInfoPlistFile|Touch|ExtractAppIntentsMetadata|ValidateEmbeddedBinary|RegisterExecutionPolicyException) ' | tail -n 1 | sed 's/ $//')"
                if [ -n "$xcode_phase" ]; then
                    status="$xcode_phase"
                fi
            fi

            if tail -n 50 "$log_file" 2>/dev/null | grep -qE '^\*\* ARCHIVE SUCCEEDED'; then
                status="archive succeeded"
            elif tail -n 50 "$log_file" 2>/dev/null | grep -qE '^\*\* ARCHIVE FAILED'; then
                status="archive FAILED"
            elif tail -n 50 "$log_file" 2>/dev/null | grep -qE '^EXPORT SUCCEEDED'; then
                status="export succeeded"
            fi
        fi

        now=$(date +%s); elapsed=$((now - start))
        em=$((elapsed / 60)); es=$((elapsed % 60))
        local s="${spin[i % 4]}"; i=$((i + 1))

        local line
        line=$(printf "  [%s]   %s  total %02d:%02d  |  %s" \
                      "$s" "$label" "$em" "$es" "$status")
        render_progress "$line"
    done

    wait "$pid"
    local ec=$?
    clear_progress_line
    return $ec
}

# Run an xcodebuild invocation with full output redirected to a log file
# (preserved for debugging), showing only a single-line progress display.
# On failure, dump the last 60 lines so the real error is visible without
# scrolling through thousands of compile commands.
run_xcodebuild_with_progress() {
    local log_file="$1"
    local label="$2"
    shift 2

    info "$label  (log: $log_file)"
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY-RUN: $*"
        return 0
    fi

    set +e
    "$@" > "$log_file" 2>&1 &
    local pid=$!
    wait_xcode_with_progress "$pid" "$log_file" "$label"
    local ec=$?
    set -e

    if [ $ec -ne 0 ]; then
        echo ""
        echo "--- Last 60 lines of $(basename "$log_file") ---"
        tail -n 60 "$log_file"
        echo "--- (full log: $log_file) ---"
        fail "$label failed (exit $ec)."
    fi
    ok "$label done"
}

# Ensure the login keychain is unlocked AND the signing identity's private
# keys have been authorized for the codesign tool. Without this, a headless
# SSH session hits errSecInternalComponent on the first `.framework` codesign
# step in `xcodebuild archive`.
unlock_keychain_for_codesign() {
    local pass="$1"
    local kc="$HOME/Library/Keychains/login.keychain-db"

    if [ -z "$pass" ]; then
        warn "mac.keychainPassword is empty; skipping keychain unlock. If xcodebuild"
        warn "fails with errSecInternalComponent, set it in config.local.json."
        return 0
    fi

    info "Unlocking login keychain for codesign"
    if ! security unlock-keychain -p "$pass" "$kc" >/dev/null 2>&1; then
        warn "security unlock-keychain returned non-zero (wrong password or keychain missing?)"
    fi
    # Grant codesign access to private keys without an interactive "Allow"
    # prompt. Idempotent; safe to re-run.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$pass" "$kc" >/dev/null 2>&1 \
        || warn "security set-key-partition-list failed (cert may not be in login.keychain)"
    # Extend lock timeout so the keychain doesn't auto-lock mid-archive.
    security set-keychain-settings -t 7200 "$kc" >/dev/null 2>&1 || true
}

# ---------- Preflight ----------
section "build_mac.sh — Unity cross-platform local build orchestrator"
[ -f "$CONFIG_FILE" ] || fail "Config missing: $CONFIG_FILE. Copy config.example.json -> config.local.json on the Mac."
command -v jq      >/dev/null 2>&1 || fail "jq not installed. Run: brew install jq"
command -v xcrun   >/dev/null 2>&1 || fail "Xcode command-line tools not installed. Run: xcode-select --install"

PRODUCT_NAME="$(cfg '.productName')"
[ -n "$PRODUCT_NAME" ] && [ "$PRODUCT_NAME" != "null" ] || fail "productName must be set in config.local.json."

MAC_APP_NAME="$(cfg '.build.macAppName // ""')"
if [ -z "$MAC_APP_NAME" ] || [ "$MAC_APP_NAME" = "null" ]; then MAC_APP_NAME="${PRODUCT_NAME}.app"; fi

UNITY="$(cfg '.unity.macEditorPath')"
MAC_BUILD_DIR="$(cfg '.paths.macBuildDir')"
IOS_BUILD_DIR="$(cfg '.paths.iosBuildDir')"
STEAM_USER="$(cfg '.steam.username // ""')"
STEAM_APPID="$(cfg '.steam.appId // ""')"
STEAM_DEPOT_MAC="$(cfg '.steam.depotIdMacOS // ""')"
STEAM_CMD_MAC="$(cfg '.steam.steamCmdPathMac // ""')"

ASC_KEY_ID="$(cfg '.testFlight.ascApiKeyId // ""')"
ASC_ISSUER="$(cfg '.testFlight.ascApiIssuerId // ""')"
ASC_P8_PATH="$(cfg '.testFlight.ascApiKeyP8Path // ""')"
TEAM_ID="$(cfg '.testFlight.teamId // ""')"
SCHEME="$(cfg '.testFlight.scheme // "Unity-iPhone"')"
EXPORT_METHOD="$(cfg '.testFlight.exportMethod // "app-store-connect"')"

KEYCHAIN_PASS="$(cfg '.mac.keychainPassword // ""')"

# CLEAR_CACHE: env/CLI wins; if still empty, fall back to config.unity.clearCacheBeforeBuild.
if [ -z "$CLEAR_CACHE" ]; then
    CLEAR_CACHE="$(cfg '.unity.clearCacheBeforeBuild // false')"
fi

[ -f "$UNITY" ] || fail "Unity editor not found at $UNITY"
ok "Unity: $UNITY"

# Expand ~ in ASC_P8_PATH if set.
if [ -n "$ASC_P8_PATH" ] && [ "${ASC_P8_PATH:0:1}" = "~" ]; then
    ASC_P8_PATH="${HOME}${ASC_P8_PATH:1}"
fi

echo "  Product:      $PRODUCT_NAME"
echo "  Branch:       $BRANCH"
echo "  Description:  ${DESCRIPTION:-(none)}"
echo "  Skip iOS:     $SKIP_IOS"
echo "  Skip macOS:   $SKIP_MACOS"
echo "  Skip uploads: $SKIP_UPLOADS"
echo "  Clear cache:  $CLEAR_CACHE"
echo "  Dry run:      $DRY_RUN"

# ---------- Unity runner ----------
run_unity() {
    local method="$1"
    local build_target="$2"
    shift 2
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local method_safe
    method_safe="$(echo "$method" | tr '.' '_')"
    local log_file="$OUTPUT_DIR/unity-$method_safe-$stamp.log"
    local report_file="$OUTPUT_DIR/report-$method_safe.json"
    rm -f "$report_file"

    info "Unity: $method  (log: $log_file)"
    local args=(
        -batchmode
        -quit
        -projectPath "$REPO_ROOT"
        -logFile "$log_file"
        -executeMethod "$method"
        -cliReportPath "$report_file"
    )
    if [ -n "$build_target" ]; then args+=(-buildTarget "$build_target"); fi
    args+=("$@")

    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY-RUN: $UNITY ${args[*]}"
        return 0
    fi

    local label="${method##*.}"
    set +e
    wait_unity_with_progress "$UNITY" "$log_file" "$label" "${args[@]}"
    local ec=$?
    set -e
    if [ $ec -ne 0 ]; then
        fail "Unity $method failed (exit $ec). Log: $log_file"
    fi

    if [ -f "$report_file" ] && command -v jq >/dev/null 2>&1; then
        local success
        success="$(jq -r '.success // false' "$report_file")"
        if [ "$success" != "true" ]; then
            fail "Unity $method reported failure: $(jq -r '.message // "unknown"' "$report_file"). Log: $log_file"
        fi
    fi
}

# ---------- Clear Unity caches (optional, before any Unity build) ----------
if [ "$CLEAR_CACHE" = "true" ]; then
    clear_unity_cache
fi

# ---------- iOS ----------
if [ "$SKIP_IOS" != "true" ]; then
    section "iOS build (append)"
    # Append mode = don't nuke the Xcode project folder. Just ensure it exists.
    mkdir -p "$IOS_BUILD_DIR"

    run_unity "$UNITY_CLASS.iOS" "iOS" \
        -cliBuildPath "$IOS_BUILD_DIR" \
        -cliIosAppend true

    if [ -d "$IOS_BUILD_DIR/Unity-iPhone.xcworkspace" ]; then
        ok "Xcode workspace at $IOS_BUILD_DIR/Unity-iPhone.xcworkspace"
    elif [ -d "$IOS_BUILD_DIR/Unity-iPhone.xcodeproj" ]; then
        ok "Xcode project at $IOS_BUILD_DIR/Unity-iPhone.xcodeproj"
    else
        fail "No Xcode project / workspace produced in $IOS_BUILD_DIR"
    fi

    if [ "$SKIP_UPLOADS" != "true" ] && [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER" ] && [ -n "$ASC_P8_PATH" ] && [ -n "$TEAM_ID" ]; then
        step "TestFlight: archive + upload"
        [ -f "$ASC_P8_PATH" ] || fail "App Store Connect .p8 missing at $ASC_P8_PATH"

        if [ -d "$IOS_BUILD_DIR/Unity-iPhone.xcworkspace" ]; then
            XCODE_PROJECT=(-workspace "$IOS_BUILD_DIR/Unity-iPhone.xcworkspace")
        else
            XCODE_PROJECT=(-project "$IOS_BUILD_DIR/Unity-iPhone.xcodeproj")
        fi

        ARCHIVE_PATH="$IOS_BUILD_DIR/${PRODUCT_NAME}.xcarchive"
        EXPORT_PATH="$IOS_BUILD_DIR/Export"
        EXPORT_PLIST="$IOS_BUILD_DIR/ExportOptions.plist"
        rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

        if [ "$DRY_RUN" != "true" ]; then
            cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$EXPORT_METHOD</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF
        fi

        unlock_keychain_for_codesign "$KEYCHAIN_PASS"

        IOS_STAMP="$(date +%Y%m%d-%H%M%S)"
        XCODE_ARCHIVE_LOG="$OUTPUT_DIR/xcodebuild-archive-$IOS_STAMP.log"
        XCODE_EXPORT_LOG="$OUTPUT_DIR/xcodebuild-export-$IOS_STAMP.log"

        run_xcodebuild_with_progress "$XCODE_ARCHIVE_LOG" "iOS archive" \
            xcodebuild "${XCODE_PROJECT[@]}" \
                -scheme "$SCHEME" \
                -configuration Release \
                -destination "generic/platform=iOS" \
                -archivePath "$ARCHIVE_PATH" \
                -allowProvisioningUpdates \
                -authenticationKeyID "$ASC_KEY_ID" \
                -authenticationKeyIssuerID "$ASC_ISSUER" \
                -authenticationKeyPath "$ASC_P8_PATH" \
                archive

        run_xcodebuild_with_progress "$XCODE_EXPORT_LOG" "iOS export" \
            xcodebuild -exportArchive \
                -archivePath "$ARCHIVE_PATH" \
                -exportPath "$EXPORT_PATH" \
                -exportOptionsPlist "$EXPORT_PLIST" \
                -allowProvisioningUpdates \
                -authenticationKeyID "$ASC_KEY_ID" \
                -authenticationKeyIssuerID "$ASC_ISSUER" \
                -authenticationKeyPath "$ASC_P8_PATH"

        if [ "$DRY_RUN" != "true" ]; then
            IPA_FILE="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' | head -n 1)"
            [ -f "$IPA_FILE" ] || fail "IPA not found after export in $EXPORT_PATH"
            info "xcrun altool upload-app -> TestFlight"
            run xcrun altool --upload-app \
                --type ios \
                --file "$IPA_FILE" \
                --apiKey "$ASC_KEY_ID" \
                --apiIssuer "$ASC_ISSUER"
            ok "TestFlight: uploaded $(basename "$IPA_FILE")"
        else
            info "DRY-RUN: would export IPA and call altool --upload-app"
        fi
    else
        warn "TestFlight upload: skipped (missing testFlight.* config or --skip-uploads). Xcode project ready at $IOS_BUILD_DIR"
    fi
fi

# ---------- macOS ----------
if [ "$SKIP_MACOS" != "true" ]; then
    section "macOS build"
    clean_dir "$MAC_BUILD_DIR"
    MAC_APP_PATH="$MAC_BUILD_DIR/$MAC_APP_NAME"

    run_unity "$UNITY_CLASS.MacOS" "OSXUniversal" \
        -cliBuildPath "$MAC_APP_PATH"

    [ -d "$MAC_APP_PATH" ] || fail "macOS .app not produced at $MAC_APP_PATH"
    mac_size_mb="$(du -sm "$MAC_APP_PATH" | cut -f1)"
    ok "macOS .app at $MAC_APP_PATH  (${mac_size_mb} MB)"

    if [ "$SKIP_UPLOADS" != "true" ] && [ -n "$STEAM_USER" ] && [ -n "$STEAM_APPID" ] && [ -n "$STEAM_DEPOT_MAC" ]; then
        step "Steam upload (macOS)"
        DEPLOY_ARGS=(
            -u "$STEAM_USER"
            -a "$STEAM_APPID"
            -D "$STEAM_DEPOT_MAC"
            -c "$MAC_BUILD_DIR"
            -n "$PRODUCT_NAME"
            -b "$BRANCH"
            -y
        )
        if [ -n "$DESCRIPTION" ]; then DEPLOY_ARGS+=(-d "$DESCRIPTION"); fi
        if [ -n "$STEAM_CMD_MAC" ];  then DEPLOY_ARGS+=(-s "$STEAM_CMD_MAC"); fi
        if [ "$DRY_RUN" = "true" ]; then
            info "DRY-RUN: $REPO_ROOT/Tools/Steam/deploy_mac.sh ${DEPLOY_ARGS[*]}"
        else
            bash "$REPO_ROOT/Tools/Steam/deploy_mac.sh" "${DEPLOY_ARGS[@]}"
            ok "Steam (macOS) upload complete."
        fi
    else
        skip "Steam (macOS) upload (steam.* not fully configured or --skip-uploads)"
    fi
fi

section "build_mac.sh done"
[ "$SKIP_IOS"   = "true" ] && echo "iOS:   skipped"  || echo "iOS:   $IOS_BUILD_DIR"
[ "$SKIP_MACOS" = "true" ] && echo "macOS: skipped"  || echo "macOS: $MAC_BUILD_DIR"
