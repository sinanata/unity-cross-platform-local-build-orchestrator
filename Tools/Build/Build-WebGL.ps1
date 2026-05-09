#Requires -Version 5.1
<#
.SYNOPSIS
  Generic WebGL build entry point. Designed to be invoked as a submodule
  by Unity OSS demo repos via a thin shim.

.DESCRIPTION
  Reads the consumer repo's Tools/Build/config.local.json, runs Unity in
  batchmode against the caller-supplied -UnityMethod, optionally serves
  the build for smoke testing, optionally pushes to gh-pages.

  Mirrors the multi-platform Build-All.ps1 hardening:
    - Stale UnityLockfile cleanup (recovers from a hard kill / BSOD).
    - Process-tree kill on Ctrl+C / throw so AssetImportWorker can't
      keep the project lock open.
    - Live single-line progress driven by Unity's DisplayProgressbar
      log markers.
    - Native NTSTATUS exit-code labelling (segfault, stack overflow…).
    - Burst-AOT cache-corruption auto-retry (one shot after wiping
      Library/BurstCache).
    - JSON build report: orchestrator validates success via the report
      file even when ExitCode is unreadable.

  All output (Unity logs, JSON reports) lands in the CONSUMER repo's
  Tools/Build/output/ — the orchestrator submodule stays clean.

.PARAMETER Title
  Banner shown at startup, e.g. "Unity 3D-to-Sprite Baker - Demo Build".

.PARAMETER UnityMethod
  Fully-qualified static method, e.g. "SpriteBakerDemo.BuildTools.BuildCli.BuildWebGL".
  The consumer repo ships its own Assets/Editor/BuildCli.cs implementing it.

.PARAMETER LiveUrl
  Optional public URL printed in the summary when -Deploy is used,
  e.g. "https://sinanata.github.io/your-repo/".

.PARAMETER RepoRoot
  Absolute path to the consumer's repo root. The shim derives this from
  its own $PSScriptRoot. The Unity project, config.local.json, and
  output/ all live under this root.

.PARAMETER ConfigPath
  Absolute path to the consumer's config.local.json. The shim usually
  passes "$RepoRoot/Tools/Build/config.local.json".

.PARAMETER Serve
  After build, run `npx serve` on the configured port for a local smoke test.

.PARAMETER Deploy
  After build, push to gh-pages via the orchestrator's Deploy-GhPages.ps1.

.PARAMETER ClearCache
  Wipe Library/BurstCache, Library/Bee, Library/ScriptAssemblies, Temp
  before invoking Unity. Triggers a full reimport.

.PARAMETER DryRun
  Print every command without executing it.

.PARAMETER Yes
  Skip the plan-confirmation prompt (and the gh-pages force-push prompt
  when -Deploy is set).

.EXAMPLE
  # Typical consumer-side shim:
  & "$RepoRoot\Tools\.orchestrator\Tools\Build\Build-WebGL.ps1" `
      -Title "Unity Mesh Fracture - Demo Build" `
      -UnityMethod "MeshFractureDemo.BuildTools.BuildCli.BuildWebGL" `
      -LiveUrl "https://sinanata.github.io/unity-mesh-fracture/" `
      -RepoRoot $RepoRoot `
      -ConfigPath "$RepoRoot\Tools\Build\config.local.json" `
      @args

.NOTES
  https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
#>

param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$UnityMethod,
    [string]$LiveUrl     = "",
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ConfigPath,

    [switch]$Serve,
    [switch]$Deploy,
    [switch]$ClearCache,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RepoRoot))   { throw "RepoRoot does not exist: $RepoRoot" }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath`n      Copy Tools\Build\config.example.json to config.local.json and fill in values." }

# Build artefacts and Unity logs land in the CONSUMER's repo so the
# orchestrator submodule stays git-clean.
$OutputDir = Join-Path $RepoRoot "Tools\Build\output"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

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
function Write-Step ($t) { Write-Host ""; Write-Host "--- $t ---" -ForegroundColor Yellow }
function Write-Ok   ($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Fail ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Write-Skip ($t) { Write-Host "  [SKIP] $t" -ForegroundColor DarkGray }
function Write-Info ($t) { Write-Host "  [..]   $t" -ForegroundColor Gray }
function Write-Warn ($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Die        ($t) { Write-Fail $t; throw $t }

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:F2} GB" -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ("{0:F1} MB" -f ($bytes / 1MB)) }
    return ("{0:F0} KB" -f ($bytes / 1KB))
}

function Load-Config {
    try { return (Get-Content $ConfigPath -Raw | ConvertFrom-Json) }
    catch { Die "Failed to parse $ConfigPath : $($_.Exception.Message)" }
}

function Clean-Dir([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { Die "Clean-Dir: empty path" }
    if ($path -match "^[A-Za-z]:\\?$" -or $path.Length -lt 8) {
        Die "Refusing to clean suspicious path '$path'"
    }
    if (Test-Path $path) {
        if ($script:DryRun) { Write-Info "DRY-RUN: would clean $path" }
        else                { Write-Info "Cleaning $path"; Remove-Item -Path $path -Recurse -Force -ErrorAction Stop }
    }
    if (-not $script:DryRun) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}

# PS 5.1's Start-Process -ArgumentList <array> joins without quoting,
# splitting any value with whitespace into multiple argv slots. Pre-quote
# instead and pass a single string.
function ConvertTo-ArgString([string[]]$argv) {
    if (-not $argv) { return "" }
    return ($argv | ForEach-Object {
        if ($null -eq $_)              { '""' }
        elseif ($_ -eq '')             { '""' }
        elseif ($_ -match '[\s"]')     { '"' + ($_ -replace '"', '\"') + '"' }
        else                            { $_ }
    }) -join ' '
}

# =================================================================
# Unity process tracking — Ctrl+C / errors must not orphan AssetImportWorker
# children, which would keep Temp\UnityLockfile held and break the next run.
# =================================================================

$script:ActiveUnityPids = New-Object System.Collections.ArrayList

function Stop-ProcessTree([int]$RootPid) {
    $toKill = @(); $queue = [System.Collections.Queue]::new(); $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue(); $toKill += $current
        try {
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$current" -ErrorAction SilentlyContinue |
                ForEach-Object { $queue.Enqueue([int]$_.ProcessId) }
        } catch {}
    }
    [array]::Reverse($toKill)
    foreach ($p in $toKill) { try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {} }
}

function Stop-AllTrackedUnity {
    if ($script:ActiveUnityPids.Count -gt 0) {
        Write-Host ""; Write-Warn "Cleaning up $($script:ActiveUnityPids.Count) active Unity process tree(s)..."
        foreach ($unityPid in @($script:ActiveUnityPids)) { Stop-ProcessTree -RootPid $unityPid }
        $script:ActiveUnityPids.Clear()
    }
    Remove-StaleUnityLockfile
}

function Remove-StaleUnityLockfile {
    $lock = Join-Path $RepoRoot "Temp\UnityLockfile"
    if (-not (Test-Path $lock)) { return }
    try { Remove-Item $lock -Force -ErrorAction Stop; Write-Info "Removed stale Temp\UnityLockfile." }
    catch { Write-Warn "Temp\UnityLockfile present but locked - another Unity is running." }
}

# Native NTSTATUS exit code = Unity crashed below the C# layer; helpful
# diagnostic so the user knows it's not a build error.
function Get-NativeCrashLabel([int]$ExitCode) {
    switch ($ExitCode) {
        -1073741819 { return "STATUS_ACCESS_VIOLATION (0xC0000005) - segfault / null deref" }
        -1073741676 { return "STATUS_INTEGER_DIVIDE_BY_ZERO (0xC0000094)" }
        -1073741571 { return "STATUS_STACK_OVERFLOW (0xC00000FD)" }
        -1073740940 { return "STATUS_HEAP_CORRUPTION (0xC0000374)" }
        -1073741795 { return "STATUS_ILLEGAL_INSTRUCTION (0xC000001D)" }
        -1073741512 { return "STATUS_DLL_INIT_FAILED (0xC0000142)" }
        -1073741515 { return "STATUS_DLL_NOT_FOUND (0xC0000135)" }
        default     { return $null }
    }
}

# Burst-AOT cache corruption fingerprint: bcl.exe exits 3 with empty stderr
# after ~45s. Pattern is narrow enough that real Burst errors don't trigger
# a retry.
function Test-BurstCacheFailure([string]$LogFile) {
    if (-not $LogFile -or -not (Test-Path $LogFile)) { return $false }
    try {
        $content = Get-Content -LiteralPath $LogFile -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return $false }
        return ($content -match 'BuildFailedException:\s*Burst compiler')
    } catch { return $false }
}

function Clear-BurstCacheOnly([string]$ProjectRoot) {
    $burst = Join-Path $ProjectRoot "Library\BurstCache"
    if (Test-Path $burst) { Write-Info "Removing $burst"; Remove-Item -Path $burst -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($pat in @("Library\Bee\Burst*", "Library\Bee\artifacts\WebGLPlayerBuildProgram\AsyncPluginsFromLinker*")) {
        Get-ChildItem -Path (Join-Path $ProjectRoot $pat) -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Info "Removing $($_.FullName)"; Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Clear-UnityCache([string]$ProjectRoot) {
    $dirs = @("Library/BurstCache", "Library/Bee", "Library/ScriptAssemblies", "Temp")
    Write-Step "Clearing Unity caches ($ProjectRoot)"
    Write-Warn "Next Unity run will do a full reimport."
    foreach ($rel in $dirs) {
        $abs = Join-Path $ProjectRoot $rel
        if (Test-Path $abs) {
            if ($script:DryRun) { Write-Info "DRY-RUN: would remove $abs" }
            else                { Write-Info "Removing $abs"; Remove-Item -Path $abs -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Tail Unity's log while batchmode runs and surface live phase progress
# from `DisplayProgressbar:` markers. Returns when $Process exits.
function Wait-UnityWithProgress {
    param([System.Diagnostics.Process]$Process, [string]$LogFile, [string]$Label)
    $start = Get-Date; $phaseStart = $start; $phase = "starting..."; $offset = [int64]0
    $spinner = @('|','/','-','\'); $i = 0; $padWidth = 120

    while (-not $Process.HasExited) {
        Start-Sleep -Milliseconds 750
        if (Test-Path $LogFile) {
            try {
                $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $null = $fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs)
                $chunk = $reader.ReadToEnd(); $offset = $fs.Position
                $reader.Close(); $fs.Close()
            } catch { $chunk = "" }
            if ($chunk) {
                foreach ($line in ($chunk -split "`n")) {
                    if ($line -match '^DisplayProgressbar:\s*(.+?)\s*$' -or
                        $line -match '^DisplayProgressNotification:\s*(.+?)\s*$') {
                        $newPhase = $matches[1]
                        if ($newPhase -ne $phase) { $phase = $newPhase; $phaseStart = Get-Date }
                    }
                }
            }
        }
        $elapsed = (Get-Date) - $start; $phaseEl = (Get-Date) - $phaseStart
        $spin = $spinner[$i % 4]; $i++
        $totalStr = '{0:mm\:ss}' -f $elapsed; $phaseStr = '{0:mm\:ss}' -f $phaseEl
        $phaseShown = if ($phase.Length -gt 60) { $phase.Substring(0, 57) + '...' } else { $phase }
        $line = "  [$spin]   $Label  total $totalStr  |  $phaseShown [$phaseStr]"
        if ($line.Length -gt $padWidth) { $line = $line.Substring(0, $padWidth - 3) + '...' }
        Write-Host -NoNewline ("`r" + $line.PadRight($padWidth))
    }
    Write-Host -NoNewline ("`r" + (" " * $padWidth) + "`r")
}

function Run-Unity {
    param([string]$UnityExe, [string]$Method, [string]$BuildTarget, [string[]]$ExtraArgs)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $methodSafe = $Method.Replace(".", "_")
    $logFile    = Join-Path $OutputDir "unity-$methodSafe-$stamp.log"
    $reportFile = Join-Path $OutputDir "report-$methodSafe.json"
    if (Test-Path $reportFile) { Remove-Item $reportFile -Force }

    $argList = @(
        "-batchmode", "-quit",
        "-projectPath", $RepoRoot,
        "-logFile",     $logFile,
        "-executeMethod", $Method,
        "-cliReportPath", $reportFile
    )
    if ($BuildTarget) { $argList += @("-buildTarget", $BuildTarget) }
    if ($ExtraArgs)   { $argList += $ExtraArgs }

    if ($script:DryRun) {
        Write-Info "DRY-RUN: `"$UnityExe`" $((ConvertTo-ArgString $argList))"
        return @{ ExitCode = 0; Report = $null; LogFile = $logFile }
    }

    Write-Info "Unity: $Method  (log: $logFile)"
    $argString = ConvertTo-ArgString $argList
    $proc = Start-Process -FilePath $UnityExe -ArgumentList $argString -NoNewWindow -PassThru
    # Pin the handle so ExitCode survives the OS process exiting (PS 5.1 quirk).
    $null = $proc.Handle
    $null = $script:ActiveUnityPids.Add($proc.Id)

    $label = ($Method -split '\.')[-1]
    try {
        Wait-UnityWithProgress -Process $proc -LogFile $logFile -Label $label
        $proc.WaitForExit()
    } finally {
        $script:ActiveUnityPids.Remove($proc.Id)
    }

    $report = $null
    if (Test-Path $reportFile) {
        try { $report = Get-Content $reportFile -Raw | ConvertFrom-Json } catch { $report = $null }
    }
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }
    if ($null -eq $exitCode) {
        if ($report -and ($report.PSObject.Properties.Name -contains 'success') -and $report.success) { $exitCode = 0 }
        else { $exitCode = -1 }
    }
    return @{ ExitCode = $exitCode; Report = $report; LogFile = $logFile }
}

function Invoke-Unity-OrDie {
    param([string]$UnityExe, [string]$Method, [string]$BuildTarget, [string[]]$ExtraArgs, [string]$Label)
    $r = Run-Unity -UnityExe $UnityExe -Method $Method -BuildTarget $BuildTarget -ExtraArgs $ExtraArgs

    $burstFailed = ($r.ExitCode -ne 0) -and (-not (Get-NativeCrashLabel $r.ExitCode)) -and (Test-BurstCacheFailure $r.LogFile)
    if ($burstFailed) {
        Write-Warn "$Label hit a Burst-AOT cache failure (bcl.exe exit 3, empty stderr)."
        Write-Warn "Auto-clearing Library/BurstCache and retrying ONCE before failing."
        if (-not $script:DryRun) { Clear-BurstCacheOnly -ProjectRoot $RepoRoot }
        $r = Run-Unity -UnityExe $UnityExe -Method $Method -BuildTarget $BuildTarget -ExtraArgs $ExtraArgs
        if ($r.ExitCode -eq 0) { Write-Ok "$Label succeeded on Burst-cache retry." }
        else                   { Write-Warn "$Label still failed after Burst-cache clear; falling through." }
    }

    if ($r.ExitCode -ne 0) {
        $crash = Get-NativeCrashLabel $r.ExitCode
        if ($crash) {
            $crashDir = Join-Path $env:TEMP "Unity\Editor\Crashes"
            Die @"
${Label}: Unity crashed in native code (exit $($r.ExitCode) = $crash).
       This is a Unity Editor crash, not a build error.
  Unity log:    $($r.LogFile)
  Crash dumps:  $crashDir   (open the most recent Crash_* folder)

  Recovery:
   1. Re-run with -ClearCache (nukes Library/Bee, BurstCache, ScriptAssemblies, Temp).
   2. Confirm Library/EditorInstance.json + Temp/UnityLockfile are gone.
"@
        }
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

Write-Section $Title

$Config = Load-Config
Write-Ok "Config:  $ConfigPath"

$UnityWin = $Config.unity.windowsEditorPath
if (-not $UnityWin)             { Die "unity.windowsEditorPath missing in $ConfigPath." }
if (-not (Test-Path $UnityWin)) { Die "Unity editor not found at: $UnityWin (check unity.windowsEditorPath)" }
Write-Ok "Unity:   $UnityWin"

Remove-StaleUnityLockfile

$BuildDir = if ([System.IO.Path]::IsPathRooted($Config.paths.buildDir)) {
    $Config.paths.buildDir
} else {
    Join-Path $RepoRoot $Config.paths.buildDir
}
$DoClearCache = [bool]$ClearCache -or [bool]$Config.unity.clearCacheBeforeBuild

if ($Deploy) {
    Push-Location $RepoRoot
    try { $null = & git rev-parse --is-inside-work-tree 2>$null }
    catch { Die "git not available or not inside a git repo." }
    finally { Pop-Location }

    $deployScript = Join-Path $PSScriptRoot "Deploy-GhPages.ps1"
    if (-not (Test-Path $deployScript)) { Die "Deploy-GhPages.ps1 missing at $deployScript (orchestrator submodule incomplete?)" }
}

# =================================================================
# Plan & confirmation
# =================================================================

Write-Section "Plan"
Write-Host "  Repo:          $RepoRoot"
Write-Host "  Build dir:     $BuildDir"
Write-Host "  Unity method:  $UnityMethod"
Write-Host "  Clear cache:   $DoClearCache"
Write-Host "  Serve:         $($Serve.IsPresent)"
Write-Host "  Deploy:        $($Deploy.IsPresent)"
Write-Host "  Dry run:       $($DryRun.IsPresent)"
Write-Host ""

if (-not $Yes -and -not $DryRun) {
    $confirm = Read-Host "Proceed? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "Aborted." -ForegroundColor Red; exit 0
    }
}

# =================================================================
# Build
# =================================================================

try {
    $OverallStart = Get-Date

    if ($DoClearCache) { Clear-UnityCache -ProjectRoot $RepoRoot }

    Write-Section "Build WebGL"
    Clean-Dir $BuildDir

    $extra = @("-cliBuildPath", $BuildDir)
    $r = Invoke-Unity-OrDie -UnityExe $UnityWin -Method $UnityMethod `
            -BuildTarget "WebGL" -ExtraArgs $extra -Label "WebGL build"

    if ($DryRun) {
        Write-Info "DRY-RUN: would produce $BuildDir\index.html"
    } else {
        $indexPath = Join-Path $BuildDir "index.html"
        if (-not (Test-Path $indexPath)) { Die "index.html not produced at $indexPath" }
        $totalBytes = (Get-ChildItem -Path $BuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-Ok "WebGL: $BuildDir  ($(Format-Size $totalBytes))"
        if ($r.Report -and $r.Report.durationSec) {
            Write-Info ("Build took {0:F1}s" -f $r.Report.durationSec)
        }
    }

    # =================================================================
    # Deploy (optional)
    # =================================================================

    if ($Deploy -and -not $DryRun) {
        Write-Section "Deploy to gh-pages"
        $deployScript = Join-Path $PSScriptRoot "Deploy-GhPages.ps1"
        $remote = if ($Config.deploy -and $Config.deploy.remoteName)    { $Config.deploy.remoteName }    else { "origin" }
        $branch = if ($Config.deploy -and $Config.deploy.branchName)    { $Config.deploy.branchName }    else { "gh-pages" }
        $msg    = if ($Config.deploy -and $Config.deploy.commitMessage) { $Config.deploy.commitMessage } else { "deploy demo ({sha})" }
        & $deployScript -BuildDir $BuildDir -RepoRoot $RepoRoot `
            -RemoteName $remote -BranchName $branch `
            -CommitMessageTemplate $msg -Yes:$Yes
        if ($LASTEXITCODE -ne 0) { Die "Deploy-GhPages.ps1 failed (exit $LASTEXITCODE)." }
        Write-Ok "gh-pages updated."
    } elseif ($Deploy -and $DryRun) {
        Write-Info "DRY-RUN: would invoke Deploy-GhPages.ps1"
    }

    # =================================================================
    # Serve (optional)
    # =================================================================

    if ($Serve -and -not $DryRun) {
        $port = if ($Config.serve -and $Config.serve.port) { [int]$Config.serve.port } else { 3000 }
        Write-Section "Serving build"
        Write-Info "npx serve $BuildDir -p $port"
        Write-Info "Press Ctrl+C to stop. URL: http://localhost:$port"
        # Foreground; user terminates with Ctrl+C.
        & npx serve $BuildDir -p $port
    } elseif ($Serve -and $DryRun) {
        Write-Info "DRY-RUN: would run npx serve $BuildDir"
    }

    $elapsed = (Get-Date) - $OverallStart
    Write-Section "Done in $([math]::Floor($elapsed.TotalMinutes)) min $([math]::Floor($elapsed.TotalSeconds) % 60) sec"
    Write-Host "  Build:  $BuildDir"
    if ($Deploy -and $LiveUrl) { Write-Host "  Live:   $LiveUrl" }
    Write-Host ""
} finally {
    Stop-AllTrackedUnity
}
