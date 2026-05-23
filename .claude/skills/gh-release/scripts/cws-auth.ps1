#!/usr/bin/env pwsh
# One-time OAuth dance to mint a CWS refresh_token.
#
# Reads CWS_CLIENT_ID + CWS_CLIENT_SECRET from releases/cws-publish.env
# (override with -EnvFile), spins up a local HTTP listener on
# http://localhost:8888, opens a browser to Google's consent page, captures
# the redirected ?code=, exchanges it for a refresh_token, and writes
# CWS_REFRESH_TOKEN back into the env file.
#
# Prereqs:
#  - GCP OAuth client of type "Desktop" with http://localhost as an
#    authorized redirect URI (or, more precisely, ANY localhost works for
#    Desktop clients — Google ignores port for the match).
#  - The Chrome Web Store API enabled in the same GCP project.
#  - You've added your Google account as a Test User on the OAuth consent
#    screen (External / Testing mode).

[CmdletBinding()]
param(
    [int]$Port = 8888,
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

function Write-EnvFile {
    param([string]$Path, [hashtable]$Map)
    $known = @('CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN', 'CWS_EXTENSION_ID')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Chrome Web Store publish credentials. DO NOT commit this file.')
    [void]$sb.AppendLine('# Lives in releases/ which is gitignored — but never `git add -f` this.')
    [void]$sb.AppendLine('# Re-run .claude/skills/gh-release/scripts/cws-auth.ps1 to mint CWS_REFRESH_TOKEN.')
    foreach ($k in $known) {
        $v = if ($Map.ContainsKey($k)) { $Map[$k] } else { '' }
        [void]$sb.AppendLine("$k=$v")
    }
    Set-Content -Path $Path -Value $sb.ToString().TrimEnd() -Encoding UTF8 -NoNewline
}

$envMap = Read-EnvFile -Path $EnvFile
$clientId     = $envMap['CWS_CLIENT_ID']
$clientSecret = $envMap['CWS_CLIENT_SECRET']

if (-not $clientId -or -not $clientSecret) {
    throw "CWS_CLIENT_ID / CWS_CLIENT_SECRET missing from $EnvFile. Populate it from your GCP OAuth client JSON first."
}

$redirectUri = "http://localhost:$Port"
$scope       = 'https://www.googleapis.com/auth/chromewebstore'
$state       = [Guid]::NewGuid().ToString('N')

$authUrl = "https://accounts.google.com/o/oauth2/v2/auth" +
           "?response_type=code" +
           "&access_type=offline" +
           "&prompt=consent" +                                          # force a fresh refresh_token even on re-auth
           "&client_id=$clientId" +
           "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
           "&scope=$([uri]::EscapeDataString($scope))" +
           "&state=$state"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
} catch {
    throw "Couldn't bind http://localhost:$Port/. Is another process using the port? Re-run with -Port <free-port>. ($($_.Exception.Message))"
}

Write-Host "Opening browser to Google consent screen..." -ForegroundColor Cyan
Start-Process $authUrl

Write-Host "Waiting for redirect to $redirectUri ..." -ForegroundColor Cyan
$context = $listener.GetContext()
$query = $context.Request.Url.Query   # e.g. "?code=4/0Ab...&scope=...&state=..."

# Respond to the browser so the user sees a "you can close this tab" page.
$html = "<html><body style='font-family:system-ui;padding:2em'><h2>OAuth complete — you can close this tab.</h2><p>Return to your terminal.</p></body></html>"
$buf = [Text.Encoding]::UTF8.GetBytes($html)
$context.Response.ContentType = 'text/html'
$context.Response.OutputStream.Write($buf, 0, $buf.Length)
$context.Response.OutputStream.Close()
$listener.Stop()

# Parse code + state
$qParams = @{}
foreach ($pair in ($query.TrimStart('?') -split '&')) {
    $kv = $pair -split '=', 2
    if ($kv.Count -eq 2) { $qParams[$kv[0]] = [uri]::UnescapeDataString($kv[1]) }
}

if ($qParams['state'] -ne $state) {
    throw "OAuth state mismatch — possible CSRF. Aborting."
}
if (-not $qParams['code']) {
    throw "No authorization code in redirect. Query was: $query"
}

Write-Host "Exchanging code for refresh_token..." -ForegroundColor Cyan
$tokenResp = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
    code          = $qParams['code']
    client_id     = $clientId
    client_secret = $clientSecret
    redirect_uri  = $redirectUri
    grant_type    = 'authorization_code'
}

if (-not $tokenResp.refresh_token) {
    throw "Token response had no refresh_token. Did you set prompt=consent? Full response: $($tokenResp | ConvertTo-Json -Depth 4)"
}

$envMap['CWS_REFRESH_TOKEN'] = $tokenResp.refresh_token
Write-EnvFile -Path $EnvFile -Map $envMap

Write-Host "Refresh token written to $EnvFile" -ForegroundColor Green
Write-Host "If CWS_EXTENSION_ID is still empty, find your extension ID in the CWS Developer Dashboard and add it manually." -ForegroundColor Yellow
