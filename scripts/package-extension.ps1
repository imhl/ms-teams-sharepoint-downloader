#!/usr/bin/env pwsh
# Package the extension into ms-teams-downloader-v<version>.zip at the repo root.
# Reads version from src/manifest.json. Refuses to overwrite an existing zip.
#
# Usage:
#   pwsh scripts/package-extension.ps1
#   pwsh scripts/package-extension.ps1 -Force        # overwrite existing zip

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (parent of this script's dir)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$srcDir = Join-Path $repoRoot 'src'
$manifestPath = Join-Path $srcDir 'manifest.json'

if (-not (Test-Path $manifestPath)) {
    throw "manifest.json not found at $manifestPath"
}

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
$version = $manifest.version
if (-not $version) { throw 'version missing from manifest.json' }

$zipName = "ms-teams-downloader-v$version.zip"
$zipPath = Join-Path $repoRoot $zipName

if (Test-Path $zipPath) {
    if ($Force) {
        Remove-Item $zipPath -Force
    } else {
        throw "$zipName already exists. Bump the version in src/manifest.json or pass -Force."
    }
}

# Excluded files inside src/ that should never ship to the Web Store
$excluded = @('key.pem', '.DS_Store', 'Thumbs.db')

$staging = Join-Path ([IO.Path]::GetTempPath()) ("ttd_pkg_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Get-ChildItem -Path $srcDir -Recurse -File | Where-Object { $excluded -notcontains $_.Name } | ForEach-Object {
        $rel = $_.FullName.Substring($srcDir.Length + 1)
        $dest = Join-Path $staging $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $sizeKb = [Math]::Round(((Get-Item $zipPath).Length / 1KB), 1)
    Write-Host "Packaged $zipName ($sizeKb KB)" -ForegroundColor Green
    Write-Host "  -> $zipPath"
} finally {
    Remove-Item -Recurse -Force $staging
}
