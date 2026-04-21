<#
.SYNOPSIS
    Deploy a Unity Windows build to Steam via SteamCMD.

.DESCRIPTION
    Generates VDF files on the fly from the app/depot IDs you pass in, uploads
    via SteamCMD, and cleans up. No committed VDFs — all config is CLI-driven.

    Normally invoked by Tools/Build/Build-All.ps1 with values from config.local.json,
    but you can call it directly for one-off uploads too.

.PARAMETER Username
    Steam partner account username. Required on first run; cached by SteamCMD
    for ~30 days after a successful Steam Guard prompt.

.PARAMETER AppId
    Steam App ID (numeric string).

.PARAMETER DepotId
    Steam Depot ID for the Windows content (numeric string).

.PARAMETER ContentRoot
    Absolute path to the Unity Windows build output directory. All files in
    here (minus excluded patterns) go into the depot.

.PARAMETER ProductName
    Your game's product name. Used only for VDF descriptions.

.PARAMETER Branch
    Steam branch to publish to. Use 'default' for the main/public branch.
    Defaults to 'closed_testing'.

.PARAMETER Preview
    Run SteamCMD in preview mode (verifies file list + sizes, no actual upload).

.PARAMETER Description
    Optional build description visible in the Steamworks partner dashboard.

.PARAMETER Yes
    Skip the "Deploy to '<branch>' branch? (y/N)" prompt.

.PARAMETER SteamCmdPath
    Path to steamcmd.exe. Defaults to C:\steamcmd\steamcmd.exe.

.EXAMPLE
    .\deploy.ps1 -Username mysteamuser -AppId 123456 -DepotId 123457 `
                 -ContentRoot D:\Builds\YourGameWinBuild -ProductName YourGame

.EXAMPLE
    .\deploy.ps1 -Username mysteamuser -AppId 123456 -DepotId 123457 `
                 -ContentRoot D:\Builds\YourGameWinBuild -ProductName YourGame `
                 -Branch default -Description "v0.2.0"

.NOTES
    https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
    Originally built for https://leapoflegends.com
#>

param(
    [Parameter(Mandatory = $true)] [string]$Username,
    [Parameter(Mandatory = $true)] [string]$AppId,
    [Parameter(Mandatory = $true)] [string]$DepotId,
    [Parameter(Mandatory = $true)] [string]$ContentRoot,
    [Parameter(Mandatory = $true)] [string]$ProductName,
    [Parameter(Mandatory = $false)][string]$Branch = "closed_testing",
    [Parameter(Mandatory = $false)][switch]$Preview,
    [Parameter(Mandatory = $false)][string]$Description,
    [Parameter(Mandatory = $false)][switch]$Yes,
    [Parameter(Mandatory = $false)][string]$SteamCmdPath = "C:\steamcmd\steamcmd.exe"
)

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
$OutputDir  = Join-Path $ScriptRoot "output"
$TempDir    = Join-Path $ScriptRoot "tmp"

# --- Validation ---
if (-not (Test-Path $SteamCmdPath)) {
    Write-Error "SteamCMD not found at $SteamCmdPath. Install it ($([char]0x2192) https://developer.valvesoftware.com/wiki/SteamCMD) or pass -SteamCmdPath."
    exit 1
}

if (-not (Test-Path $ContentRoot)) {
    Write-Error "Build directory not found: $ContentRoot. Run your Unity build first."
    exit 1
}

# --- Ensure output + temp directories exist ---
foreach ($d in @($OutputDir, $TempDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- Generate depot VDF ---
# Content root + file exclusions. We escape backslashes for VDF quoting.
function VdfEscape([string]$s) { return $s -replace '\\', '\\' }

$depotVdfPath = Join-Path $TempDir "depot_build_$DepotId.vdf"
$appVdfPath   = Join-Path $TempDir "app_build_$AppId.vdf"

$depotVdf = @"
"DepotBuildConfig"
{
    "DepotID" "$DepotId"
    "contentroot" "$(VdfEscape $ContentRoot)"
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
"@

Set-Content -Path $depotVdfPath -Value $depotVdf -Encoding UTF8

# --- Generate app VDF ---
$desc     = if ($Description) { $Description } else { "$ProductName - $Branch build" }
$previewN = if ($Preview)     { "1" }           else { "0" }

$appVdf = @"
"appbuild"
{
    "appid" "$AppId"
    "desc" "$desc"
    "buildoutput" "$(VdfEscape $OutputDir)"
    "contentroot" "$(VdfEscape $ContentRoot)"
    "setlive" "$Branch"
    "preview" "$previewN"
    "depots"
    {
        "$DepotId" "$(VdfEscape $depotVdfPath)"
    }
}
"@

Set-Content -Path $appVdfPath -Value $appVdf -Encoding UTF8

# --- Summary ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  $ProductName Steam Deploy (Windows)"   -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  App ID:      $AppId"
Write-Host "  Depot ID:    $DepotId"
Write-Host "  Branch:      $Branch"
Write-Host "  Build Dir:   $ContentRoot"
Write-Host "  Preview:     $Preview"
if ($Description) {
    Write-Host "  Description: $Description"
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Build size estimate ---
$BuildSize = (Get-ChildItem -Path $ContentRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
$BuildSizeMB = [math]::Round($BuildSize / 1MB, 2)
Write-Host "Build size: $BuildSizeMB MB" -ForegroundColor Yellow
Write-Host ""

# --- Confirmation ---
if (-not $Preview -and -not $Yes) {
    $Confirm = Read-Host "Deploy to '$Branch' branch? (y/N)"
    if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
        Write-Host "Aborted." -ForegroundColor Red
        Remove-Item $depotVdfPath, $appVdfPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
}

# --- Execute SteamCMD ---
Write-Host "Starting SteamCMD upload..." -ForegroundColor Green
Write-Host ""

$SteamArgs = @(
    "+login", $Username,
    "+run_app_build", $appVdfPath,
    "+quit"
)

$Process = Start-Process -FilePath $SteamCmdPath -ArgumentList $SteamArgs -NoNewWindow -Wait -PassThru

# --- Cleanup temp VDFs ---
Remove-Item $depotVdfPath, $appVdfPath -Force -ErrorAction SilentlyContinue

# --- Result ---
Write-Host ""
if ($Process.ExitCode -eq 0) {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Deploy SUCCESSFUL"                      -ForegroundColor Green
    Write-Host "  Branch: $Branch"                        -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Go to https://partner.steamgames.com/apps/builds/$AppId"
    Write-Host "  2. Verify the build appears on the '$Branch' branch"
    Write-Host "  3. Add testers via Steamworks partner site if not already done"
    Write-Host ""
} else {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  Deploy FAILED (exit code: $($Process.ExitCode))" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - Check Steam Guard: SteamCMD may need a 2FA code"
    Write-Host "  - Verify credentials: ensure your account has upload permissions"
    Write-Host "  - If auth issues, delete C:\steamcmd\config\config.vdf and re-auth"
    Write-Host "  - Check output logs in: $OutputDir"
    Write-Host ""
    exit $Process.ExitCode
}
