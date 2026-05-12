#!/bin/bash
#
# Deploy a Unity macOS build to Steam via SteamCMD.
#
# Generates VDF files on the fly from the app/depot IDs you pass in, uploads
# via SteamCMD, and cleans up. No committed VDFs — all config is CLI-driven.
#
# Normally invoked by Tools/Build/build_mac.sh with values from config.local.json.
#
# Usage:
#   ./deploy_mac.sh -u USER -a APPID -D DEPOT_ID -c CONTENT_ROOT -n PRODUCT [-b BRANCH] [-d DESC] [-p] [-y] [-s /path/to/steamcmd.sh]
#
# Example:
#   ./deploy_mac.sh -u mysteamuser -a 123456 -D 123458 \
#                   -c ~/Documents/YourGameMacOSBuild -n YourGame
#
# https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
# Originally built for https://leapoflegends.com

set -euo pipefail

# --- Defaults ---
USERNAME=""
APP_ID=""
DEPOT_ID=""
CONTENT_ROOT=""
PRODUCT_NAME=""
BRANCH="closed_testing"
PREVIEW=false
DESCRIPTION=""
YES=false
STEAMCMD_PATH="$HOME/Steam/steamcmd.sh"
# Alternate default if the .sh isn't present.
[ -x "$STEAMCMD_PATH" ] || STEAMCMD_PATH="$HOME/Steam/steamcmd"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
TEMP_DIR="$SCRIPT_DIR/tmp"

# --- Parse arguments ---
usage() {
    cat <<'EOF'
Usage: deploy_mac.sh -u USER -a APPID -D DEPOT_ID -c CONTENT_ROOT -n PRODUCT [options]

Required:
  -u  Steam partner account username
  -a  Steam App ID (numeric)
  -D  Steam Depot ID for macOS content (numeric)
  -c  Content root — absolute path to the Unity macOS build dir
  -n  Product name — used only for the VDF description

Options:
  -b  Steam branch (default: closed_testing). Use 'default' for main branch.
  -d  Build description shown in Steamworks dashboard
  -p  Preview mode (no actual upload)
  -y  Skip confirmation prompt (for scripted usage)
  -s  Path to steamcmd.sh / steamcmd (default: ~/Steam/steamcmd.sh)
  -h  Show this help
EOF
    exit 1
}

while getopts "u:a:D:c:n:b:d:ps:yh" opt; do
    case $opt in
        u) USERNAME="$OPTARG" ;;
        a) APP_ID="$OPTARG" ;;
        D) DEPOT_ID="$OPTARG" ;;
        c) CONTENT_ROOT="$OPTARG" ;;
        n) PRODUCT_NAME="$OPTARG" ;;
        b) BRANCH="$OPTARG" ;;
        d) DESCRIPTION="$OPTARG" ;;
        p) PREVIEW=true ;;
        s) STEAMCMD_PATH="$OPTARG" ;;
        y) YES=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# --- Validation ---
for v in USERNAME APP_ID DEPOT_ID CONTENT_ROOT PRODUCT_NAME; do
    if [ -z "${!v}" ]; then
        echo "Error: $v is required." >&2
        usage
    fi
done

# Expand ~ in STEAMCMD_PATH.
if [ "${STEAMCMD_PATH:0:1}" = "~" ]; then STEAMCMD_PATH="${HOME}${STEAMCMD_PATH:1}"; fi

if [ ! -x "$STEAMCMD_PATH" ] && [ ! -f "$STEAMCMD_PATH" ]; then
    echo "Error: SteamCMD not found at $STEAMCMD_PATH" >&2
    echo "Install it:  mkdir -p ~/Steam && cd ~/Steam && curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz' | tar zxvf -" >&2
    exit 1
fi

if [ ! -d "$CONTENT_ROOT" ]; then
    echo "Error: Content root not found: $CONTENT_ROOT" >&2
    echo "Run your Unity macOS build first." >&2
    exit 1
fi

# Find the .app bundle (for reporting only; SteamCMD doesn't need it directly).
APP_BUNDLE=$(find "$CONTENT_ROOT" -maxdepth 1 -name "*.app" -type d | head -1)
if [ -z "$APP_BUNDLE" ]; then
    echo "Error: No .app bundle found in $CONTENT_ROOT. Build appears incomplete." >&2
    exit 1
fi
APP_BASENAME=$(basename "$APP_BUNDLE")

mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

# --- Generate depot VDF ---
DEPOT_VDF="$TEMP_DIR/depot_build_${DEPOT_ID}.vdf"
APP_VDF="$TEMP_DIR/app_build_${APP_ID}.vdf"

cat > "$DEPOT_VDF" <<EOF
"DepotBuildConfig"
{
    "DepotID" "$DEPOT_ID"
    "contentroot" "$CONTENT_ROOT"
    "FileMapping"
    {
        "LocalPath" "*"
        "DepotPath" "."
        "recursive" "1"
    }
    "FileExclusion" "*.pdb"
    "FileExclusion" "*.log"
    "FileExclusion" "*_BurstDebugInformation_DoNotShip*"
    "FileExclusion" "*_BackUpThisFolder_ButDontShipItWithYourGame*"
}
EOF

DESC="${DESCRIPTION:-$PRODUCT_NAME - $BRANCH build}"
PREVIEW_N="0"
[ "$PREVIEW" = true ] && PREVIEW_N="1"

cat > "$APP_VDF" <<EOF
"appbuild"
{
    "appid" "$APP_ID"
    "desc" "$DESC"
    "buildoutput" "$OUTPUT_DIR"
    "contentroot" "$CONTENT_ROOT"
    "setlive" "$BRANCH"
    "preview" "$PREVIEW_N"
    "depots"
    {
        "$DEPOT_ID" "$DEPOT_VDF"
    }
}
EOF

cleanup() { rm -f "$DEPOT_VDF" "$APP_VDF"; }
trap cleanup EXIT

# --- Summary ---
echo ""
echo "========================================"
echo "  $PRODUCT_NAME Steam Deploy (macOS)"
echo "========================================"
echo "  App ID:      $APP_ID"
echo "  Depot ID:    $DEPOT_ID"
echo "  Branch:      $BRANCH"
echo "  Build Dir:   $CONTENT_ROOT"
echo "  App Bundle:  $APP_BASENAME"
echo "  Preview:     $PREVIEW"
if [ -n "$DESCRIPTION" ]; then echo "  Description: $DESCRIPTION"; fi
echo "========================================"
echo ""

# --- Build size estimate ---
BUILD_SIZE=$(du -sm "$CONTENT_ROOT" | cut -f1)
echo "Build size: ${BUILD_SIZE} MB"
echo ""

# --- Confirmation ---
if [ "$PREVIEW" = false ] && [ "$YES" = false ]; then
    read -rp "Deploy to '$BRANCH' branch? (y/N) " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- Execute SteamCMD ---
# Wrapped in a watchdog + HTTP-401 auto-retry. Why:
#
#  1. steamcmd has NO internal upload timeout. On HTTP 401 from the
#     steampipe CDN (during the depot manifest pre-fetch), it just
#     prints a `.` every ~11s and silently retries forever until
#     something else kills it. Observed in the wild as a build_mac.sh
#     blocked for ~10 minutes before steamcmd gave up on its own.
#     A wall-clock watchdog gives the orchestrator a bounded failure.
#
#  2. The 401 itself is recoverable: it's almost always a stale entry
#     in `~/Library/Application Support/Steam/depotcache/` referencing
#     a manifest the CDN no longer serves under the current session's
#     CDN token. Clearing depotcache (fully regenerable, does NOT touch
#     auth tokens in `config/`) and re-running once is the fix.
#
# Note: invoking via steamcmd.sh (preferred above) auto-handles SteamCMD's
# self-update protocol, where the binary returns MAGIC_RESTART_EXITCODE=42
# after pulling a new client; the wrapper re-execs itself transparently.
# When falling back to the bare binary, exit 42 will reach this script and
# is reported below.

echo "Starting SteamCMD upload..."
echo ""

# Override default with STEAM_TIMEOUT_SEC env var.
STEAM_TIMEOUT_SEC="${STEAM_TIMEOUT_SEC:-1800}"
STAMP="$(date +%Y%m%d-%H%M%S)"
STEAMCMD_LOG="$OUTPUT_DIR/steamcmd_mac_${STAMP}.log"
STEAMCMD_RETRY_LOG="$OUTPUT_DIR/steamcmd_mac_${STAMP}.retry.log"

# Spawn a watchdog that kills the steamcmd subtree if it runs past the
# timeout. `pkill -P $$` confines the kill to descendants of *this*
# script (steamcmd.sh wrapper -> steamcmd binary), so we never reap an
# unrelated Steam client the user might have running on the GUI.
# `2>&1 | tee` captures the same output we'd normally see on stdout
# AND writes it to a log file we can grep for the 401 pattern below.
# PIPESTATUS[0] is the exit code of steamcmd itself (not tee).
run_steamcmd_once() {
    local log_file="$1"

    (
        sleep "$STEAM_TIMEOUT_SEC"
        if pgrep -P $$ -f steamcmd >/dev/null 2>&1; then
            echo "" >> "$log_file"
            echo "[deploy_mac.sh] WATCHDOG: ${STEAM_TIMEOUT_SEC}s wall-clock timeout — killing steamcmd subtree." >> "$log_file"
            pkill -TERM -P $$ -f steamcmd 2>/dev/null
            sleep 2
            pkill -KILL -P $$ -f steamcmd 2>/dev/null
        fi
    ) &
    local wd_pid=$!

    set +e
    "$STEAMCMD_PATH" +login "$USERNAME" +run_app_build "$APP_VDF" +quit 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    kill "$wd_pid" 2>/dev/null
    wait "$wd_pid" 2>/dev/null || true

    return $rc
}

# Recognises the specific pattern that triggers infinite retries.
# Real auth failures (wrong password, account lacks app permission)
# fail-fast with different messages and don't match.
is_manifest_401_failure() {
    local log_file="$1"
    [ -f "$log_file" ] || return 1
    grep -qE 'Failed to download manifest.*\(HTTP 401\)' "$log_file"
}

clear_depotcache() {
    local cache="$HOME/Library/Application Support/Steam/depotcache"
    if [ -d "$cache" ]; then
        local size
        size="$(du -sh "$cache" 2>/dev/null | cut -f1)"
        echo "  [..] Clearing Steam depotcache (${size:-?})"
        rm -rf "$cache"
    fi
}

EXIT_CODE=0
run_steamcmd_once "$STEAMCMD_LOG" || EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ] && is_manifest_401_failure "$STEAMCMD_LOG"; then
    echo ""
    echo "  [WARN] steamcmd hit HTTP 401 on a depot manifest download."
    echo "  [WARN] Clearing Steam depotcache and retrying ONCE."
    clear_depotcache
    EXIT_CODE=0
    run_steamcmd_once "$STEAMCMD_RETRY_LOG" || EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "  [OK]   Steam upload succeeded on depotcache-cleared retry."
    fi
fi

# --- Result ---
echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "========================================"
    echo "  Deploy SUCCESSFUL"
    echo "  Branch: $BRANCH"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. https://partner.steamgames.com/apps/builds/$APP_ID"
    echo "  2. Verify the build appears on the '$BRANCH' branch"
    echo ""
else
    echo "========================================"
    echo "  Deploy FAILED (exit code: $EXIT_CODE)"
    echo "========================================"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check Steam Guard: SteamCMD may need a 2FA code"
    echo "  - Verify credentials: your account needs upload permissions on app $APP_ID"
    echo "  - Full steamcmd transcript: $OUTPUT_DIR/steamcmd_mac_*.log"
    echo "    (the *.retry.log variant exists if the 401 auto-retry path ran)"
    echo "  - If auth issues, delete ~/Steam/config/config.vdf and re-authenticate"
    echo "  - If WATCHDOG fired (search the log), the upload was killed for"
    echo "    running past STEAM_TIMEOUT_SEC (default 1800s). Re-run after"
    echo "    investigating whatever stalled — Valve CDN issue, network, or"
    echo "    unexpectedly large depot."
    if [ "$EXIT_CODE" -eq 42 ]; then
        echo "  - Exit 42 = SteamCMD self-updated and asked to be re-run."
        echo "    Pass -s ~/Steam/steamcmd.sh (the wrapper) instead of the bare binary,"
        echo "    or simply re-run this command — the next launch should succeed."
    fi
    echo ""
    exit $EXIT_CODE
fi
