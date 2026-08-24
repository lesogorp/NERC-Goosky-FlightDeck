param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"

$runner = Get-Command lua -ErrorAction SilentlyContinue
if (-not $runner) { $runner = Get-Command lua53 -ErrorAction SilentlyContinue }
if (-not $runner) { $runner = Get-Command texlua -ErrorAction SilentlyContinue }

if (-not $runner) {
    Write-Host "NERC widget tests FAILED: Lua 5.3 was not found in PATH." -ForegroundColor Red
    Write-Host "Install Lua 5.3, add it to PATH, then restart VS Code." -ForegroundColor Red
    exit 1
}

Push-Location $Workspace
try {
    & $runner.Source "tests/run_tests.lua"
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    if ($code -ne 0) {
        Write-Host ("NERC widget tests FAILED (exit " + $code + ")") -ForegroundColor Red
        exit $code
    }

    Write-Host "NERC widget tests PASSED" -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
