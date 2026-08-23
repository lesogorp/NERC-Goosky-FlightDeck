param(
    [string]$Drive = 'D:\'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Join-Path $RepoRoot 'SDCARD'
$RadioRoot = [System.IO.Path]::GetFullPath($Drive)

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Repo SDCARD folder not found: $SourceRoot"
}

if (-not (Test-Path -LiteralPath $RadioRoot -PathType Container)) {
    throw "Radio USB drive not found: $RadioRoot"
}

$files = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File
if (-not $files) {
    throw "No files found under $SourceRoot"
}

Write-Host "Deploying NERC Goosky FlightDeck to $RadioRoot" -ForegroundColor Cyan
Write-Host "Files: $($files.Count)" -ForegroundColor DarkGray

# Delete only files that are owned by this repo's SDCARD tree.
foreach ($file in $files) {
    $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $target = Join-Path $RadioRoot $relative

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }
}

# Copy current repo versions to the radio, preserving the SDCARD layout.
foreach ($file in $files) {
    $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $target = Join-Path $RadioRoot $relative
    $targetDir = Split-Path -Parent $target

    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
}

Write-Host "Deploy complete." -ForegroundColor Green
