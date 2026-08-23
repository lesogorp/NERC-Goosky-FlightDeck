param(
    [ValidateSet("mk3", "gx15")]
    [string]$Target = "mk3",

    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),

    [switch]$SyncOnly
)

$ErrorActionPreference = "Stop"

function Resolve-LocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Workspace $Path))
}

function Find-SimulatorExecutable {
    param([string]$ConfiguredPath)

    if ($ConfiguredPath) {
        $candidate = Resolve-LocalPath $ConfiguredPath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        throw "Configured EdgeTX simulator executable was not found: $candidate"
    }

    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "EdgeTX\Companion 2.12\simulator.exe")
        $candidates += (Join-Path $env:ProgramFiles "EdgeTX\Companion 2.12.2\simulator.exe")
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "EdgeTX\Companion 2.12\simulator.exe")
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "EdgeTX\Companion 2.12.2\simulator.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $edgeTxRoot = Join-Path $root "EdgeTX"
        if (-not (Test-Path -LiteralPath $edgeTxRoot -PathType Container)) { continue }
        $found = Get-ChildItem -LiteralPath $edgeTxRoot -Filter "simulator.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw "EdgeTX simulator.exe was not found. Set simulatorExe in dev\simulator.local.json."
}

function Stop-ExistingSimulator {
    param([Parameter(Mandatory = $true)][string]$SimulatorExe)

    $expected = [System.IO.Path]::GetFullPath($SimulatorExe)
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "simulator*" } |
        ForEach-Object {
            try {
                if ($_.Path -and [System.IO.Path]::GetFullPath($_.Path) -ieq $expected) {
                    Write-Host "Stopping existing EdgeTX simulator process $($_.Id)..."
                    Stop-Process -Id $_.Id -Force
                    Wait-Process -Id $_.Id -ErrorAction SilentlyContinue
                }
            }
            catch {
                # Ignore inaccessible unrelated simulator processes.
            }
        }
}

$configPath = Join-Path $PSScriptRoot "simulator.local.json"
$examplePath = Join-Path $PSScriptRoot "simulator.local.example.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Missing dev\simulator.local.json. Copy dev\simulator.local.example.json to simulator.local.json and set the local EdgeTX paths/profile names."
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not $config.sdPath) {
    throw "simulator.local.json must define sdPath."
}

$targetProperty = $config.targets.PSObject.Properties[$Target]
if (-not $targetProperty) {
    throw "simulator.local.json does not define targets.$Target."
}
$targetConfig = $targetProperty.Value
$profile = [string]$targetConfig.profile
$radio = [string]$targetConfig.radio
if (-not $profile -and -not $radio) {
    throw "targets.$Target must define profile and/or radio. Using a dedicated Companion radio profile is recommended."
}

$simulatorExe = Find-SimulatorExecutable ([string]$config.simulatorExe)
$sdPath = Resolve-LocalPath ([string]$config.sdPath)
$sdSource = Join-Path $Workspace "SDCARD"
$simBackendSource = Join-Path $Workspace "dev\simulator.lua"

if (-not (Test-Path -LiteralPath $sdSource -PathType Container)) {
    throw "Repository SDCARD directory was not found: $sdSource"
}

$stopExisting = $true
if ($null -ne $config.stopExisting) { $stopExisting = [bool]$config.stopExisting }
if (-not $SyncOnly -and $stopExisting) {
    Stop-ExistingSimulator $simulatorExe
}

New-Item -ItemType Directory -Path $sdPath -Force | Out-Null
Write-Host "Merging NERC SD payload into: $sdPath"
Copy-Item -Path (Join-Path $sdSource "*") -Destination $sdPath -Recurse -Force

$injectSimulation = $true
if ($null -ne $config.injectTelemetrySimulation) {
    $injectSimulation = [bool]$config.injectTelemetrySimulation
}
$simBackendDestination = Join-Path $sdPath "WIDGETS\NERC_GSkyFD\simulator.lua"
if ($injectSimulation) {
    if (-not (Test-Path -LiteralPath $simBackendSource -PathType Leaf)) {
        throw "Simulator telemetry backend was not found: $simBackendSource"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $simBackendDestination) -Force | Out-Null
    Copy-Item -LiteralPath $simBackendSource -Destination $simBackendDestination -Force
    Write-Host "Injected dev telemetry backend."
}
elseif (Test-Path -LiteralPath $simBackendDestination -PathType Leaf) {
    Remove-Item -LiteralPath $simBackendDestination -Force
    Write-Host "Removed dev telemetry backend because injectTelemetrySimulation=false."
}

if ($SyncOnly) {
    Write-Host "Simulator SD sync complete."
    exit 0
}

$arguments = @(
    "--sd-path", ('"' + $sdPath + '"'),
    "--start-with", "sd"
)
if ($profile) {
    $arguments += @("--profile", ('"' + $profile + '"'))
}
if ($radio) {
    $arguments += @("--radio", ('"' + $radio + '"'))
}

Write-Host "Launching EdgeTX simulator target '$Target'..."
Write-Host "Simulator: $simulatorExe"
if ($profile) { Write-Host "Profile:   $profile" }
if ($radio) { Write-Host "Radio:     $radio" }
Write-Host "SD path:   $sdPath"

$process = Start-Process -FilePath $simulatorExe \
    -ArgumentList $arguments \
    -WorkingDirectory (Split-Path -Parent $simulatorExe) \
    -PassThru

Write-Host "EdgeTX simulator started (PID $($process.Id))."
