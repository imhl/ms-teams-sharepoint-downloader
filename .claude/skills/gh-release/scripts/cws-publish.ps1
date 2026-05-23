#!/usr/bin/env pwsh
# Upload a zip to the Chrome Web Store (draft) and optionally publish it.
#
# Reads CWS_CLIENT_ID / CWS_CLIENT_SECRET / CWS_REFRESH_TOKEN / CWS_EXTENSION_ID
# from releases/cws-publish.env (gitignored). Override with -EnvFile. If any
# key is missing, exits with code 2 — the calling skill should treat that as
# "user hasn't opted in, skip silently".
#
# Usage:
#   pwsh cws-publish.ps1 -Zip releases/ms-teams-downloader-v1.4.2.zip          # upload only (stays in draft)
#   pwsh cws-publish.ps1 -Zip releases/...zip -Publish                          # upload + submit for review
#   pwsh cws-publish.ps1 -Zip releases/...zip -Publish -Target trustedTesters   # publish to trusted testers track

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [switch]$Publish,
    [ValidateSet('default', 'trustedTesters')][string]$Target = 'default',
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'

# Default to releases/cws-publish.env at the repo root (gitignored).
if (-not $EnvFile) {
    $repoRoot = (git rev-parse --show-toplevel 2>$null).Trim()
    if (-not $repoRoot) { throw "Not in a git repo and no -EnvFile passed." }
    $EnvFile = Join-Path $repoRoot 'releases/cws-publish.env'
}

function Read-EnvFile {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$') {
            $map[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $map
}

if (-not (Test-Path $Zip)) {
    throw "Zip not found: $Zip"
}
$Zip = (Resolve-Path $Zip).Path

$envMap = Read-EnvFile -Path $EnvFile
$required = @('CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN', 'CWS_EXTENSION_ID')
$missing  = $required | Where-Object { -not $envMap[$_] }
if ($missing) {
    Write-Host "CWS publish skipped — missing in ${EnvFile}: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "Run .claude/skills/gh-release/scripts/cws-auth.ps1 to mint a refresh_token, and add CWS_EXTENSION_ID manually." -ForegroundColor Yellow
    exit 2  # distinct exit code for "not configured" vs failure
}

$clientId     = $envMap['CWS_CLIENT_ID']
$clientSecret = $envMap['CWS_CLIENT_SECRET']
$refreshToken = $envMap['CWS_REFRESH_TOKEN']
$extensionId  = $envMap['CWS_EXTENSION_ID']

# --- 1. Refresh access token ---
Write-Host "Refreshing access token..." -ForegroundColor Cyan
try {
    $tokenResp = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
        client_id     = $clientId
        client_secret = $clientSecret
        refresh_token = $refreshToken
        grant_type    = 'refresh_token'
    }
} catch {
    throw "Token refresh failed. Most likely the refresh_token has been revoked (password change, idle >6mo, security event). Re-run cws-auth.ps1. Underlying error: $($_.Exception.Message)"
}
$accessToken = $tokenResp.access_token
if (-not $accessToken) { throw "No access_token in refresh response." }

$headers = @{
    'Authorization'    = "Bearer $accessToken"
    'x-goog-api-version' = '2'
}

# --- 2. Upload the zip (PUT — replaces the current draft) ---
Write-Host "Uploading $(Split-Path $Zip -Leaf) to extension $extensionId..." -ForegroundColor Cyan
$uploadUri = "https://www.googleapis.com/upload/chromewebstore/v1.1/items/$extensionId"
$zipBytes = [IO.File]::ReadAllBytes($Zip)
try {
    $uploadResp = Invoke-RestMethod -Method Put -Uri $uploadUri -Headers $headers -Body $zipBytes -ContentType 'application/zip'
} catch {
    $errBody = ''
    try { $errBody = $_.ErrorDetails.Message } catch { }
    throw "Upload failed: $($_.Exception.Message)`n$errBody"
}

# uploadResp.uploadState is "SUCCESS" | "FAILURE" | "IN_PROGRESS" | "NOT_FOUND"
$stateColor = if ($uploadResp.uploadState -eq 'SUCCESS') { 'Green' } else { 'Red' }
Write-Host "Upload state: $($uploadResp.uploadState)" -ForegroundColor $stateColor
if ($uploadResp.uploadState -ne 'SUCCESS') {
    if ($uploadResp.itemError) {
        foreach ($e in $uploadResp.itemError) {
            Write-Host "  - $($e.error_code): $($e.error_detail)" -ForegroundColor Red
        }
    }
    throw "Upload did not reach SUCCESS state. Fix the errors above and retry."
}

# --- 3. Optional: publish ---
if (-not $Publish) {
    Write-Host ""
    Write-Host "Draft uploaded. Review in the CWS Developer Dashboard:" -ForegroundColor Green
    Write-Host "  https://chrome.google.com/webstore/devconsole/" -ForegroundColor Green
    Write-Host "Re-run with -Publish to submit for review." -ForegroundColor Yellow
    return
}

Write-Host "Submitting for review (target: $Target)..." -ForegroundColor Cyan
$publishUri = "https://www.googleapis.com/chromewebstore/v1.1/items/$extensionId/publish"
if ($Target -ne 'default') { $publishUri += "?publishTarget=$Target" }

try {
    # Empty POST body — CWS publish endpoint takes no payload, only the URL.
    $publishResp = Invoke-RestMethod -Method Post -Uri $publishUri -Headers $headers -Body ''
} catch {
    $errBody = ''
    try { $errBody = $_.ErrorDetails.Message } catch { }
    throw "Publish failed: $($_.Exception.Message)`n$errBody"
}

# publishResp.status is an array like ["OK"] or ["NOT_AUTHORIZED"] / ["ITEM_PENDING_REVIEW"] etc.
Write-Host "Publish status: $($publishResp.status -join ', ')" -ForegroundColor Cyan
if ($publishResp.statusDetail) {
    foreach ($d in $publishResp.statusDetail) { Write-Host "  - $d" }
}

if ($publishResp.status -contains 'OK') {
    Write-Host "Submitted for review. Typical wait: hours to days. Track in the dashboard." -ForegroundColor Green
} else {
    Write-Warning "Publish returned a non-OK status. Check the dashboard."
}
