#Requires -Version 5.1
<#
.SYNOPSIS
  Force-push a WebGL build to a gh-pages orphan branch.

.DESCRIPTION
  Single-commit deploy: every push resets gh-pages to a fresh orphan
  commit, so the branch stays at exactly one commit and the public repo
  doesn't accumulate ~10 MB build artefacts per deploy.

  Uses `git worktree` so the deploy never disturbs the user's working
  tree on the source branch. The worktree is removed in the `finally`
  block on success or failure, leaving no stale state behind.

  Designed to be invoked by Build-WebGL.ps1 in the same folder, but is
  callable on its own.

.PARAMETER BuildDir
  Absolute or repo-relative path to the WebGL build output (must contain
  index.html).

.PARAMETER RepoRoot
  Absolute path to the consumer repo root (where .git lives).

.PARAMETER RemoteName
  Git remote that owns the gh-pages branch (default: origin).

.PARAMETER BranchName
  Target branch name (default: gh-pages — required by GitHub Pages
  default config).

.PARAMETER CommitMessageTemplate
  Commit message; supports the {sha} placeholder which is replaced with
  the source commit's short SHA.

.PARAMETER Yes
  Skip the "this will force-push" confirmation prompt.
#>

param(
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$RemoteName = "origin",
    [string]$BranchName = "gh-pages",
    [string]$CommitMessageTemplate = "deploy demo ({sha})",
    [switch]$Yes
)

# NOT "Stop": git writes informational text to stderr ("Switched to a new
# branch", "Preparing worktree", ...) and PS 5.1 turns every stderr line
# into a terminating NativeCommandError under Stop mode. Use explicit
# $LASTEXITCODE checks instead, plus -ErrorAction Stop on load-bearing
# Cmdlet calls below.
$ErrorActionPreference = "Continue"

function Write-Ok   ($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Info ($t) { Write-Host "  [..]   $t" -ForegroundColor Gray }
function Write-Warn ($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Die         ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red; throw $t }

# -- Validate ------------------------------------------------------------

$indexPath = Join-Path $BuildDir "index.html"
if (-not (Test-Path $indexPath)) { Die "Build output incomplete: $indexPath not found." }

if (-not (Test-Path (Join-Path $RepoRoot ".git"))) { Die "Not a git repo: $RepoRoot" }

Push-Location $RepoRoot
try {
    $remoteUrl = (& git remote get-url $RemoteName 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($remoteUrl)) {
        Die "git remote '$RemoteName' is not configured. Add it with: git remote add $RemoteName <url>"
    }
    Write-Info "Remote: $remoteUrl"

    $sourceSha = (& git rev-parse --short HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { Die "Failed to read source commit SHA." }
    Write-Info "Source SHA: $sourceSha"

    $commitMessage = $CommitMessageTemplate.Replace("{sha}", $sourceSha)

    # -- Confirm (force-push warning) -----------------------------------

    if (-not $Yes) {
        Write-Host ""
        Write-Warn "This will force-push to $RemoteName/$BranchName, replacing any existing"
        Write-Warn "branch history with a single new commit:"
        Write-Warn "  Message: $commitMessage"
        Write-Warn "  Files:   $BuildDir -> $RemoteName/$BranchName /"
        Write-Host ""
        $confirm = Read-Host "Continue? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") { Write-Host "Aborted." -ForegroundColor Red; exit 0 }
    }

    # -- Worktree setup -------------------------------------------------

    $worktreePath = Join-Path $RepoRoot ".gh-pages-tmp"

    # Defensive: a previous failed run could leave the worktree stub
    # registered in .git/worktrees/ even if the directory is gone, OR
    # leave the directory without the registration. Clean both.
    try { & git worktree remove --force $worktreePath 2>&1 | Out-Null } catch {}
    if (Test-Path $worktreePath) {
        Write-Info "Removing leftover $worktreePath"
        Remove-Item -Path $worktreePath -Recurse -Force -ErrorAction Stop
    }
    try { & git worktree prune 2>&1 | Out-Null } catch {}

    Write-Info "Creating worktree at $worktreePath"
    & git worktree add --detach $worktreePath HEAD
    if ($LASTEXITCODE -ne 0) { Die "git worktree add failed." }

    # -- Build the orphan deploy commit ---------------------------------

    Push-Location $worktreePath
    try {
        # Switch to a fresh orphan branch (locally named gh-pages-deploy
        # so it doesn't shadow the target name on the parent repo). The
        # final push retargets it to $BranchName on the remote.
        & git checkout --orphan gh-pages-deploy 2>&1 | Out-Null
        & git rm -rf . 2>&1 | Out-Null

        Write-Info "Copying $BuildDir -> $worktreePath"
        Copy-Item -Path (Join-Path $BuildDir "*") -Destination $worktreePath -Recurse -Force -ErrorAction Stop

        # GitHub Pages serves user files as-is. A `.nojekyll` file disables
        # Jekyll preprocessing, which otherwise hides folders starting with
        # underscore (Unity emits a Build/_build_settings.json on some
        # builds). Cheap insurance, no downside.
        Set-Content -Path (Join-Path $worktreePath ".nojekyll") -Value "" -Encoding ASCII -ErrorAction Stop

        & git add -A 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "git add failed." }

        # --allow-empty: re-deploying the same build is a valid no-op.
        & git commit -m $commitMessage --allow-empty 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "git commit failed." }

        Write-Info "Pushing to $RemoteName/$BranchName (force)..."
        & git push $RemoteName "HEAD:$BranchName" --force
        if ($LASTEXITCODE -ne 0) { Die "git push failed." }

        Write-Ok "Pushed deploy commit to $RemoteName/$BranchName."
    }
    finally {
        Pop-Location
    }

    Write-Info "Removing worktree"
    try { & git worktree remove --force $worktreePath 2>&1 | Out-Null } catch {}
    if (Test-Path $worktreePath) { Remove-Item -Path $worktreePath -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Cleanup complete."
}
finally {
    Pop-Location
}
