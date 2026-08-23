param(
    [string]$Drive = 'D:\'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DestRoot = Join-Path $RepoRoot 'SDCARD'
$RadioRoot = [System.IO.Path]::GetFullPath($Drive)

if (-not (Test-Path -LiteralPath $DestRoot -PathType Container)) {
    throw "Repo SDCARD folder not found: $DestRoot"
}

if (-not (Test-Path -LiteralPath $RadioRoot -PathType Container)) {
    throw "Radio USB drive not found: $RadioRoot"
}

# Use the repo tree as the manifest so unrelated files on the radio are never copied.
$manifest = Get-ChildItem -LiteralPath $DestRoot -Recurse -File
if (-not $manifest) {
    throw "No files found under $DestRoot"
}

Write-Host "Pulling NERC Goosky FlightDeck from $RadioRoot" -ForegroundColor Cyan
Write-Host "Manifest files: $($manifest.Count)" -ForegroundColor DarkGray

$copied = 0
$missing = 0

foreach ($localFile in $manifest) {
    $relative = $localFile.FullName.Substring($DestRoot.Length).TrimStart('\')
    $source = Join-Path $RadioRoot $relative

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-Warning "Missing on radio: $relative"
        $missing++
        continue
    }

    $dest = Join-Path $DestRoot $relative
    $destDir = Split-Path -Parent $dest

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # Explicit delete-before-copy so the local file is replaced cleanly.
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        Remove-Item -LiteralPath $dest -Force
    }

    Copy-Item -LiteralPath $source -Destination $dest -Force
    $copied++
}

Write-Host "Pull complete. Copied: $copied  Missing: $missing" -ForegroundColor Green
