#!/usr/bin/env pwsh
# Generate bucketed release notes for the gh-release skill.
# Reads commits in $RangeStart..HEAD, groups by conventional-commit prefix,
# strips Co-Authored-By trailers, emits markdown to stdout.

param(
    [Parameter(Mandatory = $true)][string]$RangeStart,
    [switch]$IncludeDocs,
    [switch]$CreditAll,        # credit the repo owner too (default: only non-owner contributors)
    [switch]$NoAttribution     # disable "by @login" entirely
)

$ErrorActionPreference = 'Stop'

# --- Attribution helpers ---
$BotLogins = @('renovate[bot]', 'dependabot[bot]', 'github-actions[bot]', 'web-flow')
$script:RepoOwner = $null
$script:AuthorCache = @{}

function Get-RepoOwner {
    if ($script:RepoOwner) { return $script:RepoOwner }
    try {
        $script:RepoOwner = (gh repo view --json owner --jq '.owner.login' 2>$null).Trim()
    } catch { $script:RepoOwner = '' }
    return $script:RepoOwner
}

function Resolve-CommitAuthor {
    param([string]$Sha)
    if ($script:AuthorCache.ContainsKey($Sha)) { return $script:AuthorCache[$Sha] }
    $login = $null
    try {
        $login = (gh api "repos/{owner}/{repo}/commits/$Sha" --jq '.author.login' 2>$null).Trim()
        if ($login -eq 'null' -or [string]::IsNullOrWhiteSpace($login)) { $login = $null }
    } catch { $login = $null }
    $script:AuthorCache[$Sha] = $login
    return $login
}

function Get-PrNumberFromSubject {
    param([string]$Subject)
    # GitHub squash-merge default appends "(#N)" to the subject.
    if ($Subject -match '\(#(\d+)\)\s*$') { return $Matches[1] }
    return $null
}

# Use rare separators: \x1f between fields, \x1e between commits.
# git log in PowerShell returns string[] (one per line), so join into one
# blob before splitting on the inter-commit separator.
$logFormat = '%H%x1f%h%x1f%s%x1f%b%x1e'
$raw = (git log "$RangeStart..HEAD" --no-merges --pretty=format:$logFormat) -join "`n"

if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Output "_No commits in range $RangeStart..HEAD_"
    return
}

$commits = $raw -split [char]0x1e | Where-Object { $_.Trim() } | ForEach-Object {
    $parts = $_.TrimStart("`n", "`r") -split [char]0x1f
    [PSCustomObject]@{
        Sha     = if ($parts.Count -gt 0) { $parts[0] } else { '' }
        Short   = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        Subject = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        Body    = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    }
}

function Get-Bucket {
    param($subject, $sha)
    # Demo-website-only commits → Docs bucket (filtered unless -IncludeDocs)
    # regardless of conventional-commit prefix. The extension ships separately
    # from the marketing site, so site-only changes don't belong in extension
    # release notes.
    $filesChanged = git show --name-only --pretty=format: $sha 2>$null | Where-Object { $_ }
    $allDemo = $filesChanged -and (($filesChanged | Where-Object { $_ -notlike 'demo-website/*' }).Count -eq 0)

    if ($allDemo)                                  { return 'Docs' }
    if ($subject -match '^feat(\([^)]+\))?:')     { return 'Features' }
    if ($subject -match '^fix(\([^)]+\))?:')      { return 'Bug fixes' }
    if ($subject -match '^perf(\([^)]+\))?:')     { return 'Performance' }
    if ($subject -match '^refactor(\([^)]+\))?:') { return 'Refactors' }
    if ($subject -match '^docs(\([^)]+\))?:')     { return 'Docs' }
    if ($subject -match '^chore(\([^)]+\))?:')    { return 'Docs' }
    return 'Other'
}

$bucketed = @{
    'Features'    = @()
    'Bug fixes'   = @()
    'Performance' = @()
    'Refactors'   = @()
    'Other'       = @()
    'Docs'        = @()
}

foreach ($c in $commits) {
    $subject = $c.Subject.Trim()
    # Skip generated "Co-Authored-By" / signoff trailers in subject (shouldn't be there, but defensive).
    if ($subject -match '^(Co-Authored-By|Signed-off-by):') { continue }
    $bucket = Get-Bucket $subject $c.Sha
    $bucketed[$bucket] += [PSCustomObject]@{ Sha = $c.Sha; Subject = $subject; Short = $c.Short }
}

# Render
$order = @('Features', 'Bug fixes', 'Performance', 'Refactors', 'Other')
if ($IncludeDocs) { $order += 'Docs' }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('## Highlights')
$lines.Add('')
$lines.Add('<!-- 1-2 sentence summary of what users get in this release -->')
$lines.Add('')
$lines.Add('## Changes')
$lines.Add('')

$anyEmitted = $false
foreach ($section in $order) {
    $items = $bucketed[$section]
    if (-not $items -or $items.Count -eq 0) { continue }
    $lines.Add("### $section")
    $lines.Add('')
    foreach ($item in $items) {
        # Concat — avoids tangling PowerShell's $-interpolation with markdown
        # backticks. Base output: "- subject (`abc1234`)".
        $subject = $item.Subject

        # Strip trailing "(#N)" so we can re-render it consistently.
        $prNum = Get-PrNumberFromSubject $subject
        if ($prNum) { $subject = ($subject -replace '\s*\(#\d+\)\s*$', '').Trim() }

        $line = '- ' + $subject + ' (`' + $item.Short + '`)'

        if ($prNum) { $line += " in #$prNum" }

        if (-not $NoAttribution) {
            $login = Resolve-CommitAuthor -Sha $item.Sha
            if ($login -and ($BotLogins -notcontains $login)) {
                $owner = Get-RepoOwner
                if ($CreditAll -or ($login -ne $owner)) {
                    $line += " by @$login"
                }
            }
        }

        $lines.Add($line)
    }
    $lines.Add('')
    $anyEmitted = $true
}

if (-not $anyEmitted) {
    $lines.Add('_No notable commits in range._')
}

$lines -join "`n"
