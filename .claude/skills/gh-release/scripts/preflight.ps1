#!/usr/bin/env pwsh
# Pre-flight checks for the gh-release skill. Emits JSON to stdout.
# Exit code 0 = checks ran (may still have blocking_issues); non-zero = script error.

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) { throw "Not in a git repository" }
    return $root
}

$repoRoot = Get-RepoRoot
Set-Location $repoRoot

$result = [ordered]@{
    version              = $null
    tag                  = $null
    branch               = $null
    clean_tree           = $false
    in_sync_with_origin  = $false
    tag_exists_local     = $false
    tag_exists_remote    = $false
    release_exists       = $false
    last_tag             = $null
    range_start          = $null
    range_start_source   = $null
    commits_in_range     = 0
    stale_version_refs   = @()
    zip_path             = $null
    zip_exists           = $false
    blocking_issues      = @()
}

# --- Version from manifest ---
$manifestPath = Join-Path $repoRoot 'src/manifest.json'
if (-not (Test-Path $manifestPath)) {
    $result.blocking_issues += "src/manifest.json not found"
    $result | ConvertTo-Json -Depth 6
    return
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$version = $manifest.version
if (-not $version) {
    $result.blocking_issues += "src/manifest.json has no 'version' field"
    $result | ConvertTo-Json -Depth 6
    return
}
$result.version = $version
$result.tag     = "v$version"
$result.zip_path = Join-Path $repoRoot "releases/ms-teams-downloader-v$version.zip"
$result.zip_exists = Test-Path $result.zip_path

# --- Branch ---
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$result.branch = $branch
if ($branch -ne 'main') {
    $result.blocking_issues += "Not on main (current: $branch)"
}

# --- Clean tree ---
$dirty = git status --porcelain
$result.clean_tree = [string]::IsNullOrWhiteSpace($dirty)
if (-not $result.clean_tree) {
    $result.blocking_issues += "Working tree is dirty — commit or stash first"
}

# --- In sync with origin ---
try { git fetch origin --quiet 2>&1 | Out-Null } catch { }
$ahead  = [int](git rev-list --count "origin/$branch..HEAD" 2>$null)
$behind = [int](git rev-list --count "HEAD..origin/$branch" 2>$null)
$result.in_sync_with_origin = ($ahead -eq 0) -and ($behind -eq 0)
if (-not $result.in_sync_with_origin) {
    $result.blocking_issues += "Local $branch is ahead $ahead / behind $behind vs origin — push or pull first"
}

# --- Tag existence (local + remote) ---
$result.tag_exists_local = [bool](git tag --list "v$version")
try {
    $remoteTag = git ls-remote --tags origin "refs/tags/v$version" 2>$null
    $result.tag_exists_remote = -not [string]::IsNullOrWhiteSpace($remoteTag)
} catch { $result.tag_exists_remote = $false }
if ($result.tag_exists_local -or $result.tag_exists_remote) {
    $result.blocking_issues += "Tag v$version already exists (local=$($result.tag_exists_local), remote=$($result.tag_exists_remote))"
}

# --- GH release existence ---
try {
    gh release view "v$version" 2>$null | Out-Null
    $result.release_exists = ($LASTEXITCODE -eq 0)
} catch { $result.release_exists = $false }
if ($result.release_exists) {
    $result.blocking_issues += "GitHub release v$version already exists"
}

# --- Last tag (highest semver, not just chronologically last) ---
$tags = git tag --list 'v*' --sort=-v:refname
if ($tags) {
    $result.last_tag = ($tags | Select-Object -First 1)
}

# --- Range start ---
# If there's a prior tag, use it. Otherwise find the commit that set the
# previous manifest version, and use its parent as range start (so commits
# AFTER the previous version-bump are included).
if ($result.last_tag) {
    $result.range_start = $result.last_tag
    $result.range_start_source = "previous tag"
} else {
    # Walk manifest.json history backwards to find the commit where version
    # changed FROM something else TO the current value (or the most recent
    # version-change commit if the current value is itself fresh).
    $manifestLog = git log --pretty=format:"%H" --follow -- src/manifest.json
    $prevVersionBumpSha = $null
    foreach ($sha in $manifestLog) {
        try {
            $oldContent = git show "${sha}^:src/manifest.json" 2>$null
            $newContent = git show "${sha}:src/manifest.json" 2>$null
            if (-not $oldContent -or -not $newContent) { continue }
            $oldV = ($oldContent | ConvertFrom-Json).version
            $newV = ($newContent | ConvertFrom-Json).version
            if ($oldV -and $newV -and ($oldV -ne $newV) -and ($newV -ne $version)) {
                # This is the commit that bumped to the prior version.
                $prevVersionBumpSha = $sha
                break
            }
        } catch { continue }
    }
    if ($prevVersionBumpSha) {
        $result.range_start = $prevVersionBumpSha
        $result.range_start_source = "previous version-bump commit ($prevVersionBumpSha)"
    } else {
        # Bootstrap-bootstrap: no prior version-bump found. Use root commit.
        $rootSha = (git rev-list --max-parents=0 HEAD | Select-Object -First 1).Trim()
        $result.range_start = $rootSha
        $result.range_start_source = "root commit (no prior version-bump found)"
    }
}

# --- Commits in range ---
try {
    $result.commits_in_range = [int](git rev-list --count "$($result.range_start)..HEAD" 2>$null)
} catch { $result.commits_in_range = 0 }

# --- Stale version refs ---
# Search for the previous tag/version (or any "v1.x.y" pattern) outside
# manifest.json and lockfiles. The skill will auto-bump demo-website/ paths.
$searchPatterns = @()
if ($result.last_tag) {
    $searchPatterns += [regex]::Escape($result.last_tag.TrimStart('v'))
    $searchPatterns += [regex]::Escape($result.last_tag)
}
# Also catch any older "vX.Y.Z" markers that may have been left behind.
# Use POSIX ERE (no \d — that's a PCRE extension git grep -E doesn't support).
$genericPattern = 'v[0-9]+\.[0-9]+\.[0-9]+'

$excludeGlobs = @(
    'src/manifest.json',
    '.git/**',
    '.claude/**',
    'demo-website/package-lock.json',
    'demo-website/node_modules/**',
    'ms-teams-downloader-v*.zip',
    'RELEASE_NOTES.md'
)
$excludeArgs = $excludeGlobs | ForEach-Object { ":(exclude)$_" }

$matches = git grep -nE $genericPattern -- '*' @excludeArgs 2>$null
if ($matches) {
    foreach ($line in $matches) {
        if ($line -match '^(?<path>[^:]+):(?<line>\d+):(?<content>.*)$') {
            $path = $Matches.path
            $content = $Matches.content
            $lineNum = [int]$Matches.line
            # Only flag if at least one version on the line is NOT the current.
            $allVersions = [regex]::Matches($content, 'v[0-9]+\.[0-9]+\.[0-9]+') | ForEach-Object { $_.Value.TrimStart('v') }
            $stale = $allVersions | Where-Object { $_ -ne $version }
            if (-not $stale) { continue }
            $result.stale_version_refs += [ordered]@{
                path    = $path
                line    = $lineNum
                content = $content.Trim()
            }
        }
    }
}

# --- Manifest version unchanged ---
if ($result.last_tag -and ($result.last_tag.TrimStart('v') -eq $version)) {
    $result.blocking_issues += "src/manifest.json version ($version) matches last tag ($($result.last_tag)) — bump version first"
}

# --- Emit JSON ---
$result | ConvertTo-Json -Depth 6
