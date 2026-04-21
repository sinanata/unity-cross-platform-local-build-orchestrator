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
echo "Starting SteamCMD upload..."
echo ""

"$STEAMCMD_PATH" +login "$USERNAME" +run_app_build "$APP_VDF" +quit
EXIT_CODE=$?

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
    echo "  - If auth issues, delete ~/Steam/config/config.vdf and re-authenticate"
    echo ""
    exit $EXIT_CODE
fi
