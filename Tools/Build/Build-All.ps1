#Requires -Version 5.1
<#
.SYNOPSIS
  Unity cross-platform local build orchestrator (Windows entry point).

.DESCRIPTION
  End-to-end one-command release automation:
    1. Preflight (Unity, keystore, SteamCMD, SSH, disk).
    2. Bump bundleVersion + AndroidBundleVersionCode + iOS/macOS buildNumber.
    3. Build Android AAB -> optionally upload to Play Internal Testing.
    4. Build Windows -> upload to Steam.
    5. git commit version bump, push.
    6. SSH to MacBook -> git reset --hard origin -> build iOS (append) ->
       optional TestFlight upload -> build macOS -> upload to Steam.

  Reads Tools/Build/config.local.json. See config.example.json for layout,
  and docs/CREDENTIALS.md for how to gather every required credential.

  Pairs with:
    - Assets/Editor/BuildCli.cs     (Unity batchmode entry points)
    - Tools/Build/build_mac.sh      (Mac-side runner, invoked over SSH)
    - Tools/Steam/deploy.ps1        (Steam Windows deploy)
    - Tools/Build/upload_play.py    (Google Play Publishing API)

.PARAMETER Bump
  none | patch (default) | minor | major.

.PARAMETER Branch
  Steam branch name. Defaults to config.steam.defaultBranch (falls back to
  'closed_testing').

.PARAMETER Description
  Optional Steam build description / Play release-notes string.

.PARAMETER SkipAndroid / SkipWindows / SkipiOS / SkipMacOS
  Skip that entire platform (build + upload).

.PARAMETER SkipStoreUploads
  Produce artefacts locally, but do not upload anything.

.PARAMETER SkipVersionBump
  Use current ProjectSettings version; do not bump.

.PARAMETER SkipCommit / SkipPush
  Do not git commit / push the version-bump commit.

.PARAMETER DryRun
  Print every command without executing it.

.PARAMETER Yes
  Skip the plan-confirmation prompt.

.PARAMETER ClearCache
  Remove Library/BurstCache, Library/Bee, Library/ScriptAssemblies, and Temp
  before the first Unity invocation. Forces a full reimport (+5-15 min).
  Use to recover from stale-cache issues such as NetCode "RpcSystem failed
  to deserialize RPC ... bits read X did not match expected Y". Also
  settable persistently via unity.clearCacheBeforeBuild in config.local.json.

.PARAMETER ConfigPath
  Alternate config file (defaults to Tools/Build/config.local.json).

.EXAMPLE
  .\Tools\Build\Build-All.ps1
  .\Tools\Build\Build-All.ps1 -Bump minor -Description "v0.2.0 release"
  .\Tools\Build\Build-All.ps1 -SkipiOS -SkipMacOS
  .\Tools\Build\Build-All.ps1 -SkipStoreUploads -DryRun

.NOTES
  https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
  Originally built for https://leapoflegends.com
#>

param(
    [ValidateSet("none", "patch", "minor", "major")]
    [string]$Bump = "patch",

    [string]$Branch = "",

    [string]$Description = "",

    [switch]$SkipAndroid,
    [switch]$SkipWindows,
    [switch]$SkipiOS,
    [switch]$SkipMacOS,

    [switch]$SkipStoreUploads,
    [switch]$SkipVersionBump,
    [switch]$SkipCommit,
    [switch]$SkipPush,

    [switch]$DryRun,
    [switch]$Yes,
    [switch]$ClearCache,

    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$RepoRoot   = (Resolve-Path (Join-Path $ScriptRoot "..\..")).Path
$OutputDir  = Join-Path $ScriptRoot "output"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Unity batchmode entry-point class (matches BuildCli.cs namespace).
$UnityClass = "BuildOrchestrator.Cli.BuildCli"

# =================================================================
# Helpers
# =================================================================

function Write-Section($text) {
    $bar = ("=" * 72)
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
}

function Write-Step($text) {
    Write-Host ""
    Write-Host "--- $text ---" -ForegroundColor Yellow
}

function Write-Ok   ($text) { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Fail ($text) { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Skip ($text) { Write-Host "  [SKIP] $text" -ForegroundColor DarkGray }
function Write-Info ($text) { Write-Host "  [..]   $text" -ForegroundColor Gray }
function Write-Warn ($text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }

function Die($text) {
    Write-Fail $text
    throw $text
}

function Resolve-UserPath([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return $null }
    if ($path.StartsWith("~")) {
        $base = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        $tail = $path.Substring(1).TrimStart("/").TrimStart("\")
        return Join-Path $base $tail
    }
    return $path
}

function Load-Config {
    $path = if ($script:ConfigPath) { $script:ConfigPath } else { Join-Path $ScriptRoot "config.local.json" }
    if (-not (Test-Path $path)) {
        Die "Config not found: $path`n      Copy Tools\Build\config.example.json to config.local.json and fill in values.`n      See docs/CREDENTIALS.md for the step-by-step."
    }
    try {
        return (Get-Content $path -Raw | ConvertFrom-Json)
    } catch {
        Die "Failed to parse $path : $($_.Exception.Message)"
    }
}

function Clean-Dir([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { Die "Clean-Dir: empty path" }
    if ($path -match "^[A-Za-z]:\\?$" -or $path.Length -lt 8) {
        Die "Refusing to clean suspicious path '$path'"
    }
    if (Test-Path $path) {
        if ($script:DryRun) {
            Write-Info "DRY-RUN: would clean $path"
        } else {
            Write-Info "Cleaning $path"
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
        }
    }
    if (-not $script:DryRun) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# Nuke Unity's Burst AOT + Bee + assembly caches so the next Unity invocation
# regenerates everything from scratch. Recovery tool for stale-cache issues
# like NetCode "RpcSystem failed to deserialize RPC ... bits read X did not
# match expected Y" where server+client disagree on wire format within one
# process. Expensive (full reimport, +5-15 min) but deterministic.
function Clear-UnityCache([string]$ProjectRoot) {
    $dirs = @("Library/BurstCache", "Library/Bee", "Library/ScriptAssemblies", "Temp")
    Write-Step "Clearing Unity caches ($ProjectRoot)"
    Write-Warn "Next Unity run will do a full reimport."
    foreach ($rel in $dirs) {
        $abs = Join-Path $ProjectRoot $rel
        if (Test-Path $abs) {
            if ($script:DryRun) {
                Write-Info "DRY-RUN: would remove $abs"
            } else {
                Write-Info "Removing $abs"
                Remove-Item -Path $abs -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:F2} GB" -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ("{0:F1} MB" -f ($bytes / 1MB)) }
    return ("{0:F0} KB" -f ($bytes / 1KB))
}

# Escape for bash single-quoted string (used when building the remote SSH command).
function Bash-SingleQuote([string]$s) {
    if ($null -eq $s) { return "''" }
    return "'" + ($s -replace "'", "'\''") + "'"
}

# Redact sensitive flag values when echoing a command line for logs / dry-run.
function Mask-Sensitive([string[]]$arr) {
    $sensitive = @("-cliKeystorePass", "-cliKeyaliasPass")
    $out = New-Object System.Collections.Generic.List[string]
    $mask = $false
    foreach ($a in $arr) {
        if ($mask) { $out.Add("***"); $mask = $false; continue }
        if ($sensitive -contains $a) { $out.Add($a); $mask = $true } else { $out.Add($a) }
    }
    return $out.ToArray()
}

# Build a Windows command-line string from an argv[] array, quoting any
# element that contains whitespace or a double quote. PS 5.1's
# Start-Process -ArgumentList <array> joins without quoting — which splits
# values like "my key alias" into two argv slots. This helper returns a
# single pre-quoted string we can hand to Start-Process as-is.
function ConvertTo-ArgString([string[]]$argv) {
    if (-not $argv) { return "" }
    return ($argv | ForEach-Object {
        if ($null -eq $_)                { '""' }
        elseif ($_ -eq '')               { '""' }
        elseif ($_ -match '[\s"]')       { '"' + ($_ -replace '"', '\"') + '"' }
        else                              { $_ }
    }) -join ' '
}

# Poll the Unity log file while the editor is running and render a live
# single-line progress display driven by the 'DisplayProgressbar:' markers
# Unity writes for every build phase. Returns when $Process exits.
function Wait-UnityWithProgress {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$LogFile,
        [string]$Label
    )
    $start      = Get-Date
    $phaseStart = $start
    $phase      = "starting..."
    $offset     = [int64]0
    $spinner    = @('|','/','-','\')
    $i          = 0
    $padWidth   = 120

    while (-not $Process.HasExited) {
        Start-Sleep -Milliseconds 750

        if (Test-Path $LogFile) {
            try {
                $fs = [System.IO.File]::Open(
                    $LogFile,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                $null = $fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs)
                $chunk  = $reader.ReadToEnd()
                $offset = $fs.Position
                $reader.Close()
                $fs.Close()
            } catch {
                $chunk = ""
            }

            if ($chunk) {
                foreach ($line in ($chunk -split "`n")) {
                    if ($line -match '^DisplayProgressbar:\s*(.+?)\s*$') {
                        $newPhase = $matches[1]
                        if ($newPhase -ne $phase) { $phase = $newPhase; $phaseStart = Get-Date }
                    }
                    elseif ($line -match '^DisplayProgressNotification:\s*(.+?)\s*$') {
                        $newPhase = $matches[1]
                        if ($newPhase -ne $phase) { $phase = $newPhase; $phaseStart = Get-Date }
                    }
                    elseif ($line -match '^BuildPlayer:\s*start building target') {
                        if (-not ($phase -match '^(Building|Incremental|Compiling)')) {
                            $phase = "BuildPlayer starting"; $phaseStart = Get-Date
                        }
                    }
                }
            }
        }

        $elapsed  = (Get-Date) - $start
        $phaseEl  = (Get-Date) - $phaseStart
        $spin     = $spinner[$i % 4]; $i++
        $totalStr = '{0:mm\:ss}' -f $elapsed
        $phaseStr = '{0:mm\:ss}' -f $phaseEl

        $phaseShown = if ($phase.Length -gt 60) { $phase.Substring(0, 57) + '...' } else { $phase }
        $line = "  [$spin]   $Label  total $totalStr  |  $phaseShown [$phaseStr]"
        if ($line.Length -gt $padWidth) { $line = $line.Substring(0, $padWidth - 3) + '...' }

        Write-Host -NoNewline ("`r" + $line.PadRight($padWidth))
    }

    # Clear the progress line so the caller's [OK]/[FAIL] message starts clean.
    Write-Host -NoNewline ("`r" + (" " * $padWidth) + "`r")
}

# =================================================================
# Unity process tracking — so Ctrl+C / errors don't leave zombies.
# Unity spawns AssetImportWorker children that don't receive console
# Ctrl+C; if orphaned they keep Temp/UnityLockfile held and every
# subsequent build fails immediately with "PrintVersion exit 1".
# =================================================================

$script:ActiveUnityPids = New-Object System.Collections.ArrayList

function Stop-ProcessTree([int]$RootPid) {
    # Kill all descendants bottom-up, then the root. Swallow "no such
    # process" errors — normal if the tree already exited cleanly.
    $toKill = @()
    $queue  = [System.Collections.Queue]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $toKill += $current
        try {
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$current" -ErrorAction SilentlyContinue |
                ForEach-Object { $queue.Enqueue([int]$_.ProcessId) }
        } catch {}
    }
    # Reverse so children die before parents (avoids re-parenting to PID 1).
    [array]::Reverse($toKill)
    foreach ($p in $toKill) {
        try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Stop-AllTrackedUnity {
    if ($script:ActiveUnityPids.Count -eq 0) { return }
    Write-Host ""
    Write-Warn "Cleaning up $($script:ActiveUnityPids.Count) active Unity process tree(s)..."
    foreach ($unityPid in @($script:ActiveUnityPids)) {
        Stop-ProcessTree -RootPid $unityPid
    }
    $script:ActiveUnityPids.Clear()
    # Unity holds Temp/UnityLockfile while running; if we just killed it,
    # the file may linger and block the next run. Remove it.
    $lock = Join-Path $RepoRoot "Temp\UnityLockfile"
    if (Test-Path $lock) {
        try {
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
            Write-Info "Removed stale Temp\UnityLockfile."
        } catch {}
    }
}

function Run-Unity {
    param(
        [string]$UnityExe,
        [string]$Method,
        [string]$BuildTarget,
        [string[]]$ExtraArgs
    )
    $stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
    $methodSafe  = $Method.Replace(".", "_")
    $logFile     = Join-Path $OutputDir "unity-$methodSafe-$stamp.log"
    $reportFile  = Join-Path $OutputDir "report-$methodSafe.json"
    if (Test-Path $reportFile) { Remove-Item $reportFile -Force }

    $argList = @(
        "-batchmode",
        "-quit",
        "-projectPath", $RepoRoot,
        "-logFile",     $logFile,
        "-executeMethod", $Method,
        "-cliReportPath", $reportFile
    )
    if ($BuildTarget)       { $argList += @("-buildTarget", $BuildTarget) }
    if ($ExtraArgs)         { $argList += $ExtraArgs }

    if ($script:DryRun) {
        Write-Info "DRY-RUN: `"$UnityExe`" $((Mask-Sensitive $argList) -join ' ')"
        return @{ ExitCode = 0; Report = $null; LogFile = $logFile }
    }

    Write-Info "Unity: $Method  (log: $logFile)"
    $argString = ConvertTo-ArgString $argList
    $proc = Start-Process -FilePath $UnityExe -ArgumentList $argString -NoNewWindow -PassThru
    # PS 5.1 quirk: Start-Process -PassThru releases the Process handle the
    # moment the OS process exits, leaving ExitCode unreadable. Touching
    # .Handle now pins it for the lifetime of $proc.
    $null = $proc.Handle
    # Track for Ctrl+C / error cleanup (Stop-AllTrackedUnity in main try/finally).
    $null = $script:ActiveUnityPids.Add($proc.Id)

    $label = ($Method -split '\.')[-1]
    try {
        Wait-UnityWithProgress -Process $proc -LogFile $logFile -Label $label
        $proc.WaitForExit()
    } finally {
        # Unregister so the outer finally doesn't try to kill a PID that
        # either exited naturally or was already reaped by the inner path.
        $script:ActiveUnityPids.Remove($proc.Id)
    }

    $report = $null
    if (Test-Path $reportFile) {
        try { $report = Get-Content $reportFile -Raw | ConvertFrom-Json } catch { $report = $null }
    }

    # Fallback: trust the report file's "success" field if ExitCode is unreadable.
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }
    if ($null -eq $exitCode) {
        if ($report -and ($report.PSObject.Properties.Name -contains 'success') -and $report.success) {
            $exitCode = 0
        } else {
            $exitCode = -1
        }
    }
    return @{ ExitCode = $exitCode; Report = $report; LogFile = $logFile }
}

function Invoke-Unity-OrDie {
    param(
        [string]$UnityExe, [string]$Method, [string]$BuildTarget,
        [string[]]$ExtraArgs, [string]$Label
    )
    $r = Run-Unity -UnityExe $UnityExe -Method $Method -BuildTarget $BuildTarget -ExtraArgs $ExtraArgs
    if ($r.ExitCode -ne 0) {
        Die "$Label failed (exit $($r.ExitCode)). Full log: $($r.LogFile)"
    }
    if ($r.Report -and ($r.Report.PSObject.Properties.Name -contains 'success') -and (-not $r.Report.success)) {
        Die "$Label reported failure: $($r.Report.message). Log: $($r.LogFile)"
    }
    return $r
}

# =================================================================
# Preflight
# =================================================================

Write-Section "Unity cross-platform build orchestrator"

$Config = Load-Config
Write-Ok "Config loaded: $(if ($ConfigPath) { $ConfigPath } else { 'Tools\Build\config.local.json' })"

# Product identifiers from config.
$ProductName    = $Config.productName
if (-not $ProductName) { Die "productName must be set in config.local.json." }

$WindowsExeName = if ($Config.build.windowsExeName) { $Config.build.windowsExeName } else { "$ProductName.exe" }
$AabName        = if ($Config.build.aabName)        { $Config.build.aabName }        else { "$ProductName.aab" }

$UnityWin = $Config.unity.windowsEditorPath
if (-not (Test-Path $UnityWin)) { Die "Unity editor not found at: $UnityWin (check unity.windowsEditorPath)" }
Write-Ok "Unity: $UnityWin"

$DoAndroid   = -not $SkipAndroid
$DoWindows   = -not $SkipWindows
$DoiOS       = -not $SkipiOS
$DoMacOS     = -not $SkipMacOS
$DoMac       = $DoiOS -or $DoMacOS
$DoUploads   = -not $SkipStoreUploads
# -ClearCache CLI switch wins; otherwise fall back to unity.clearCacheBeforeBuild.
$DoClearCache = [bool]$ClearCache -or [bool]$Config.unity.clearCacheBeforeBuild

# Default Steam branch from config if caller didn't supply one.
if (-not $Branch) {
    $Branch = if ($Config.steam.defaultBranch) { $Config.steam.defaultBranch } else { "closed_testing" }
}

$SteamConfigured = $Config.steam.username -and $Config.steam.appId -and $Config.steam.depotIdWindows

if ($DoAndroid) {
    $keystoreAbs = if ([System.IO.Path]::IsPathRooted($Config.android.keystorePath)) {
        $Config.android.keystorePath
    } else {
        Join-Path $RepoRoot $Config.android.keystorePath
    }
    if (-not (Test-Path $keystoreAbs)) { Die "Android keystore not found: $keystoreAbs" }
    Write-Ok "Keystore: $keystoreAbs"

    if (-not $Config.android.keystorePassword -or $Config.android.keystorePassword -like "REPLACE*") {
        Die "android.keystorePassword is not set in config.local.json."
    }
    if (-not $Config.android.keyaliasName -or $Config.android.keyaliasName -like "REPLACE*") {
        Die "android.keyaliasName is not set in config.local.json."
    }
}

if ($DoWindows -and $DoUploads -and $SteamConfigured) {
    $SteamCmd = if ($Config.steam.steamCmdPathWindows) { $Config.steam.steamCmdPathWindows } else { "C:\steamcmd\steamcmd.exe" }
    if (-not (Test-Path $SteamCmd)) {
        Die "SteamCMD not found at $SteamCmd. Install per docs/CREDENTIALS.md § 7a, or run with -SkipStoreUploads."
    }
    Write-Ok "SteamCMD present: $SteamCmd"
}

if ($DoAndroid -and $DoUploads -and $Config.playStore.serviceAccountJsonPath) {
    $playJson = Resolve-UserPath $Config.playStore.serviceAccountJsonPath
    if (-not (Test-Path $playJson)) {
        Die "Play service account JSON missing: $playJson"
    }
    try {
        $null = & python --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "python exited $LASTEXITCODE" }
    } catch {
        Die "Python 3 not found in PATH. Install Python 3.8+ and 'pip install google-auth google-api-python-client', or leave playStore.serviceAccountJsonPath empty."
    }
    Write-Ok "Python + Play credentials present"
}

$drivesToCheck = @($Config.paths.windowsBuildDir, $Config.paths.androidBuildDir) |
    Where-Object { $_ } |
    ForEach-Object { [System.IO.Path]::GetPathRoot($_).TrimEnd('\') } |
    Sort-Object -Unique
foreach ($root in $drivesToCheck) {
    try {
        $letter = $root.TrimEnd(':')
        $drive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            if ($freeGB -lt 10) {
                Write-Warn "$root has only $freeGB GB free (recommend 10+)"
            } else {
                Write-Ok "$root has $freeGB GB free"
            }
        }
    } catch { }
}

if ($DoMac -and $Config.mac.runMode -eq "ssh") {
    if (-not $Config.mac.sshHost -or -not $Config.mac.sshUser) {
        Die "mac.sshHost / mac.sshUser must be set in config.local.json."
    }

    $sshKeyResolved = $null
    if ($Config.mac.sshKey) { $sshKeyResolved = Resolve-UserPath $Config.mac.sshKey }

    $sshProbeArgs = @(
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=6",
        "-o", "StrictHostKeyChecking=accept-new"
    )
    if ($sshKeyResolved) {
        if (Test-Path $sshKeyResolved) {
            $sshProbeArgs += @("-i", $sshKeyResolved)
        } else {
            Write-Warn "SSH key file not found: $sshKeyResolved (will try default identities)"
        }
    }
    if ($Config.mac.sshPort -and [int]$Config.mac.sshPort -ne 22) {
        $sshProbeArgs += @("-p", "$($Config.mac.sshPort)")
    }
    $sshProbeArgs += "$($Config.mac.sshUser)@$($Config.mac.sshHost)"
    $sshProbeArgs += 'echo __OK__ && uname -s && sw_vers -productVersion'

    Write-Info "SSH probe: $($Config.mac.sshUser)@$($Config.mac.sshHost)"
    if ($script:DryRun) {
        Write-Info "DRY-RUN: ssh $($sshProbeArgs -join ' ')"
    } else {
        $probeOutput = & ssh @sshProbeArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not ($probeOutput -match "__OK__")) {
            Die @"
SSH probe failed (exit $LASTEXITCODE).
Output: $probeOutput

Fix checklist:
  1. On the Mac: System Settings > General > Sharing > Remote Login = ON.
  2. 'ssh-keygen -t ed25519' on this Windows PC (no passphrase for unattended).
  3. Copy %USERPROFILE%\.ssh\id_ed25519.pub to the Mac's ~/.ssh/authorized_keys.
  4. Verify manually: ssh $($Config.mac.sshUser)@$($Config.mac.sshHost) uname
See docs/CREDENTIALS.md § 1 for the full walkthrough.
"@
        }
        Write-Ok "Mac reachable: $(($probeOutput | Where-Object { $_ -and $_ -ne '__OK__' }) -join ' ')"
    }
}

# =================================================================
# Plan and confirmation
# =================================================================

$currentGitBranch = "(unknown)"
try {
    Push-Location $RepoRoot
    $currentGitBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
} catch { } finally { Pop-Location }

$descDisplay = if ($Description) { $Description } else { "(none)" }

if     (-not $DoAndroid) { $planAndroid = "skipped" }
elseif (-not $DoUploads -or -not $Config.playStore.serviceAccountJsonPath) { $planAndroid = "build (manual Play upload)" }
else   { $planAndroid = "build + Play $($Config.playStore.track)" }

if     (-not $DoWindows) { $planWindows = "skipped" }
elseif (-not $DoUploads -or -not $SteamConfigured) { $planWindows = "build (no Steam)" }
else   { $planWindows = "build + Steam [$Branch]" }

if     (-not $DoiOS)     { $planiOS = "skipped" }
elseif (-not $DoUploads -or -not $Config.testFlight.ascApiKeyId) { $planiOS = "build append (manual TestFlight)" }
else   { $planiOS = "build append + TestFlight" }

if     (-not $DoMacOS)   { $planMacOS = "skipped" }
elseif (-not $DoUploads -or -not $SteamConfigured) { $planMacOS = "build (no Steam)" }
else   { $planMacOS = "build + Steam [$Branch]" }

Write-Section "Build plan"
Write-Host "  Product:           $ProductName"
Write-Host "  Git branch (Win):  $currentGitBranch"
Write-Host "  Version bump:      $Bump"
Write-Host "  Steam branch:      $Branch"
Write-Host "  Description:       $descDisplay"
Write-Host "  Android:           $planAndroid"
Write-Host "  Windows:           $planWindows"
Write-Host "  iOS:               $planiOS"
Write-Host "  macOS:             $planMacOS"
Write-Host "  Clear cache:       $DoClearCache"
Write-Host "  Dry run:           $($DryRun.IsPresent)"
Write-Host ""

if (-not $Yes -and -not $DryRun) {
    $confirm = Read-Host "Proceed? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "Aborted." -ForegroundColor Red
        exit 0
    }
}

# Wrap the whole build flow so Ctrl+C / Die / any exception still runs the
# Unity-cleanup finally block. Without this, orphan Unity + AssetImportWorker
# processes keep Temp/UnityLockfile held and break the next invocation.
try {

$OverallStart = Get-Date

# =================================================================
# 0. Clear Unity caches (optional, before any Unity build)
# =================================================================

if ($DoClearCache) {
    Clear-UnityCache -ProjectRoot $RepoRoot
}

# =================================================================
# 1. Version bump
# =================================================================

if (-not $SkipVersionBump -and $Bump -ne "none") {
    Write-Section "1. Bump version ($Bump)"
    $r = Invoke-Unity-OrDie -UnityExe $UnityWin -Method "$UnityClass.BumpVersion" `
        -BuildTarget "" -ExtraArgs @("-cliBumpKind", $Bump) -Label "BumpVersion"
    if ($r.Report) {
        Write-Ok "Version: $($r.Report.bundleVersion)  (code $($r.Report.androidBundleVersionCode))"
    }
} else {
    Write-Skip "Version bump"
}

$versionRun = Invoke-Unity-OrDie -UnityExe $UnityWin -Method "$UnityClass.PrintVersion" `
    -BuildTarget "" -ExtraArgs @() -Label "PrintVersion"
if ($versionRun.Report) {
    $CurrentVersion = $versionRun.Report.bundleVersion
    $CurrentCode    = [int]$versionRun.Report.androidBundleVersionCode
} elseif ($DryRun) {
    $CurrentVersion = "0.0.0-dryrun"
    $CurrentCode    = 0
    Write-Info "DRY-RUN: placeholder version (Unity not invoked)."
} else {
    Die "Could not read current version from Unity report."
}
Write-Info "Using version: $CurrentVersion (code $CurrentCode)"

# =================================================================
# 2. Android build + Play upload
# =================================================================

if ($DoAndroid) {
    Write-Section "2. Android build (AAB)"
    Clean-Dir $Config.paths.androidBuildDir
    $aabPath = Join-Path $Config.paths.androidBuildDir $AabName

    $aliasPass = if ($Config.android.keyaliasPassword -and $Config.android.keyaliasPassword -notlike "REPLACE*") {
        $Config.android.keyaliasPassword
    } else {
        $Config.android.keystorePassword
    }

    $extra = @(
        "-cliBuildPath",    $aabPath,
        "-cliKeystorePath", (Join-Path $RepoRoot $Config.android.keystorePath),
        "-cliKeystorePass", $Config.android.keystorePassword,
        "-cliKeyaliasName", $Config.android.keyaliasName,
        "-cliKeyaliasPass", $aliasPass
    )
    Invoke-Unity-OrDie -UnityExe $UnityWin -Method "$UnityClass.Android" `
        -BuildTarget "Android" -ExtraArgs $extra -Label "Android build" | Out-Null

    if ($DryRun) {
        Write-Info "DRY-RUN: would produce $aabPath"
    } else {
        if (-not (Test-Path $aabPath)) { Die "AAB not produced at $aabPath" }
        $aabSize = (Get-Item $aabPath).Length
        Write-Ok "AAB: $aabPath  ($(Format-Size $aabSize))"
    }

    if ($DoUploads -and $Config.playStore.serviceAccountJsonPath) {
        Write-Step "Play Store upload"
        $playJson = Resolve-UserPath $Config.playStore.serviceAccountJsonPath
        $playArgs = @(
            (Join-Path $ScriptRoot "upload_play.py"),
            "--service-account", $playJson,
            "--aab", $aabPath,
            "--package", $Config.playStore.packageName,
            "--track",   $Config.playStore.track
        )
        if ($Description) { $playArgs += @("--release-notes", $Description) }

        if ($DryRun) {
            Write-Info "DRY-RUN: python $($playArgs -join ' ')"
        } else {
            & python @playArgs
            $ec = $LASTEXITCODE
            if ($ec -ne 0) {
                Die "Play Store upload failed (exit $ec)."
            }
            Write-Ok "Play Store: uploaded to '$($Config.playStore.track)' track."
        }
    } else {
        Write-Skip "Play Store upload  (AAB ready for manual upload: $aabPath)"
    }
} else {
    Write-Skip "Android"
}

# =================================================================
# 3. Windows build + Steam upload
# =================================================================

if ($DoWindows) {
    Write-Section "3. Windows build"
    Clean-Dir $Config.paths.windowsBuildDir
    $exePath = Join-Path $Config.paths.windowsBuildDir $WindowsExeName

    Invoke-Unity-OrDie -UnityExe $UnityWin -Method "$UnityClass.Windows" `
        -BuildTarget "Win64" -ExtraArgs @("-cliBuildPath", $exePath) -Label "Windows build" | Out-Null

    if ($DryRun) {
        Write-Info "DRY-RUN: would produce $exePath"
    } else {
        if (-not (Test-Path $exePath)) { Die "$WindowsExeName not produced at $exePath" }
        $totalBytes = (Get-ChildItem -Path $Config.paths.windowsBuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-Ok "Windows build at $($Config.paths.windowsBuildDir)  ($(Format-Size $totalBytes))"
    }

    if ($DoUploads -and $SteamConfigured) {
        Write-Step "Steam upload (Windows)"
        $deploy = Join-Path $RepoRoot "Tools\Steam\deploy.ps1"
        # Hashtable splat binds by name and avoids PS 5.1's array-splat-with-switch quirk.
        $deploySplat = @{
            Username      = $Config.steam.username
            AppId         = $Config.steam.appId
            DepotId       = $Config.steam.depotIdWindows
            ContentRoot   = $Config.paths.windowsBuildDir
            ProductName   = $ProductName
            Branch        = $Branch
            Yes           = $true
        }
        if ($Description) { $deploySplat.Description = $Description }
        if ($Config.steam.steamCmdPathWindows) { $deploySplat.SteamCmdPath = $Config.steam.steamCmdPathWindows }

        if ($DryRun) {
            $flat = ($deploySplat.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
            Write-Info "DRY-RUN: $deploy $flat"
        } else {
            & $deploy @deploySplat
            if ($LASTEXITCODE -ne 0) { Die "Steam (Windows) upload failed (exit $LASTEXITCODE)." }
            Write-Ok "Steam (Windows) upload complete."
        }
    } elseif ($DoUploads) {
        Write-Skip "Steam (Windows) upload  (steam.username / steam.appId / steam.depotIdWindows not set)"
    } else {
        Write-Skip "Steam (Windows) upload"
    }
} else {
    Write-Skip "Windows"
}

# =================================================================
# 4. Git commit + push
# =================================================================

if (-not $SkipVersionBump -and $Bump -ne "none" -and -not $SkipCommit) {
    Write-Section "4. Git commit + push"
    Push-Location $RepoRoot
    try {
        & git add ProjectSettings/ProjectSettings.asset | Out-Null
        $status = & git status --porcelain
        if (-not $status) {
            Write-Skip "No changes staged for commit."
        } else {
            $msg = "build $CurrentVersion (code $CurrentCode)"
            if ($DryRun) {
                Write-Info "DRY-RUN: git commit -m `"$msg`""
                if (-not $SkipPush) { Write-Info "DRY-RUN: git push" }
            } else {
                & git commit -m $msg
                if ($LASTEXITCODE -ne 0) { Die "git commit failed (exit $LASTEXITCODE)." }
                Write-Ok "Committed: $msg"

                if (-not $SkipPush) {
                    & git push
                    if ($LASTEXITCODE -ne 0) { Die "git push failed (exit $LASTEXITCODE)." }
                    Write-Ok "Pushed."
                } else {
                    Write-Skip "git push  (-SkipPush set; Mac will fail to pull)"
                }
            }
        }
    } finally { Pop-Location }
} else {
    Write-Skip "Git commit + push"
}

# =================================================================
# 5. Mac-side builds (iOS + macOS)
# =================================================================

if ($DoMac) {
    Write-Section "5. Mac builds (iOS + macOS)"

    if ($Config.mac.runMode -eq "manual") {
        Write-Host ""
        Write-Host "Run this on the Mac:" -ForegroundColor Yellow
        Write-Host "  cd $($Config.paths.macRepoRoot)" -ForegroundColor Gray
        Write-Host "  git fetch --all --prune && git checkout $currentGitBranch && git reset --hard '@{u}' && git clean -fd" -ForegroundColor Gray
        $macInv = "  BRANCH=$Branch"
        if ($Description)     { $macInv += " DESCRIPTION=$(Bash-SingleQuote $Description)" }
        if ($SkipiOS)         { $macInv += " SKIP_IOS=true" }
        if ($SkipMacOS)       { $macInv += " SKIP_MACOS=true" }
        if ($SkipStoreUploads){ $macInv += " SKIP_UPLOADS=true" }
        if ($DryRun)          { $macInv += " DRY_RUN=true" }
        if ($DoClearCache)    { $macInv += " CLEAR_CACHE=true" }
        $macInv += " bash Tools/Build/build_mac.sh"
        Write-Host $macInv -ForegroundColor Gray
        Write-Host ""
    }
    elseif ($Config.mac.runMode -eq "ssh") {
        $sshKeyResolved = if ($Config.mac.sshKey) { Resolve-UserPath $Config.mac.sshKey } else { $null }
        $sshCore = @(
            "-t",
            "-o", "StrictHostKeyChecking=accept-new"
        )
        if ($sshKeyResolved -and (Test-Path $sshKeyResolved)) { $sshCore += @("-i", $sshKeyResolved) }
        if ($Config.mac.sshPort -and [int]$Config.mac.sshPort -ne 22) { $sshCore += @("-p", "$($Config.mac.sshPort)") }
        $sshCore += "$($Config.mac.sshUser)@$($Config.mac.sshHost)"

        $macRepo  = Bash-SingleQuote $Config.paths.macRepoRoot
        $gitBr    = Bash-SingleQuote $currentGitBranch
        $envKV = @(
            "BRANCH=$(Bash-SingleQuote $Branch)",
            "DESCRIPTION=$(Bash-SingleQuote $Description)",
            "SKIP_IOS=$(if ($SkipiOS)         { 'true' } else { 'false' })",
            "SKIP_MACOS=$(if ($SkipMacOS)     { 'true' } else { 'false' })",
            "SKIP_UPLOADS=$(if ($SkipStoreUploads) { 'true' } else { 'false' })",
            "DRY_RUN=$(if ($DryRun)           { 'true' } else { 'false' })",
            "CLEAR_CACHE=$(if ($DoClearCache) { 'true' } else { 'false' })"
        ) -join ' '

        # Mac is a pure build slave: fetch, hard-reset to the remote tip, and
        # wipe untracked junk so leftover modifications from a prior run (Unity
        # touching ProjectSettings.asset, stray .meta files, etc.) never block
        # the merge. '.gitignore' is respected, so config.local.json and
        # output/ logs are preserved.
        $remoteCmd = "set -e; cd $macRepo && git fetch --all --prune && git checkout $gitBr && git reset --hard '@{u}' && git clean -fd && chmod +x Tools/Build/build_mac.sh && env $envKV bash Tools/Build/build_mac.sh"

        Write-Info "Running on Mac: $($Config.mac.sshUser)@$($Config.mac.sshHost)"
        if ($DryRun) {
            Write-Info "DRY-RUN: ssh $($sshCore -join ' ') `"$remoteCmd`""
        } else {
            & ssh @sshCore $remoteCmd
            $sshExit = $LASTEXITCODE
            if ($sshExit -ne 0) {
                Die "Mac build failed (ssh exit $sshExit). Check the Mac's Tools/Build/output/ for Unity logs."
            }
            Write-Ok "Mac builds complete."
        }
    }
    else {
        Write-Warn "mac.runMode is '$($Config.mac.runMode)'; expected 'ssh' or 'manual'. Skipping Mac step."
    }
} else {
    Write-Skip "Mac (iOS + macOS)"
}

# =================================================================
# Summary
# =================================================================

$elapsed = (Get-Date) - $OverallStart
Write-Section "All done in $([math]::Floor($elapsed.TotalMinutes)) min $([math]::Floor($elapsed.TotalSeconds) % 60) sec"
Write-Host "  Version:     $CurrentVersion  (code $CurrentCode)"
Write-Host "  Android AAB: $(if ($DoAndroid) { Join-Path $Config.paths.androidBuildDir $AabName } else { 'skipped' })"
Write-Host "  Windows:     $(if ($DoWindows) { $Config.paths.windowsBuildDir } else { 'skipped' })"
Write-Host "  iOS:         $(if ($DoiOS)     { $Config.paths.iosBuildDir + '  (on Mac)' } else { 'skipped' })"
Write-Host "  macOS:       $(if ($DoMacOS)   { $Config.paths.macBuildDir + '  (on Mac)' } else { 'skipped' })"
Write-Host ""
if ($SteamConfigured) {
    Write-Host "Partner dashboards:" -ForegroundColor DarkGray
    Write-Host "  Steam:  https://partner.steamgames.com/apps/builds/$($Config.steam.appId)" -ForegroundColor DarkGray
}
if ($DoAndroid -and $Config.playStore.serviceAccountJsonPath) { Write-Host "  Play:   https://play.google.com/console/u/0/developers" -ForegroundColor DarkGray }
if ($DoiOS     -and $Config.testFlight.ascApiKeyId)           { Write-Host "  ASC:    https://appstoreconnect.apple.com/apps" -ForegroundColor DarkGray }
Write-Host ""

} finally {
    # Runs on success, on Die/throw, and on Ctrl+C (which surfaces as
    # PipelineStoppedException). Kills any still-tracked Unity process
    # tree and wipes Temp\UnityLockfile so the next run is clean.
    Stop-AllTrackedUnity
}
