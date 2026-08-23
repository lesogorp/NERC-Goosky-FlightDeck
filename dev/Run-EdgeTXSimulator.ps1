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
        $candidates += (Join-Path $env:ProgramFiles "EdgeTX\Companion 2.12\bin\simulator.exe")
        $candidates += (Join-Path $env:ProgramFiles "EdgeTX\Companion 2.12.2\bin\simulator.exe")
        $candidates += (Join-Path $env:ProgramFiles "EdgeTX\Companion 2.12\simulator.exe")
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "EdgeTX\Companion 2.12\bin\simulator.exe")
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "EdgeTX\Companion 2.12.2\bin\simulator.exe")
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "EdgeTX\Companion 2.12\simulator.exe")
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

function Resolve-TargetSdPath {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$TargetConfig,
        [Parameter(Mandatory = $true)][string]$TargetName
    )

    if ($TargetConfig.sdPath) {
        return Resolve-LocalPath ([string]$TargetConfig.sdPath)
    }

    if ($Config.sdRoot -and $TargetConfig.sdFolder) {
        $root = Resolve-LocalPath ([string]$Config.sdRoot)
        return [System.IO.Path]::GetFullPath((Join-Path $root ([string]$TargetConfig.sdFolder)))
    }

    if ($Config.sdPath) {
        return Resolve-LocalPath ([string]$Config.sdPath)
    }

    throw "No simulator SD path is configured for target '$TargetName'. Set targets.$TargetName.sdPath, or set sdRoot plus targets.$TargetName.sdFolder."
}

$configPath = Join-Path $PSScriptRoot "simulator.local.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Missing dev\simulator.local.json. Copy dev\simulator.local.example.json to simulator.local.json and set the local EdgeTX paths/profile names."
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not $config.targets) {
    throw "simulator.local.json must define targets."
}

$targetProperty = $config.targets.PSObject.Properties[$Target]
if (-not $targetProperty) {
    throw "simulator.local.json does not define targets.$Target."
}
$targetConfig = $targetProperty.Value
$profile = [string]$targetConfig.profile
$radio = [string]$targetConfig.radio
if (-not $profile -and -not $radio) {
    throw "targets.$Target must define profile and/or radio."
}

$simulatorExe = Find-SimulatorExecutable ([string]$config.simulatorExe)
$sdPath = Resolve-TargetSdPath -Config $config -TargetConfig $targetConfig -TargetName $Target
$sdSource = Join-Path $Workspace "SDCARD"
$telemetrySimSource = Join-Path $Workspace "dev\simulator.lua"
$elrsSimSource = Join-Path $Workspace "dev\elrs-simulator.lua"

if (-not (Test-Path -LiteralPath $sdSource -PathType Container)) {
    throw "Repository SDCARD directory was not found: $sdSource"
}
if (-not (Test-Path -LiteralPath $sdPath -PathType Container)) {
    throw "EdgeTX SD pack for target '$Target' was not found: $sdPath"
}

$stopExisting = $true
if ($null -ne $config.stopExisting) { $stopExisting = [bool]$config.stopExisting }
if (-not $SyncOnly -and $stopExisting) {
    Stop-ExistingSimulator $simulatorExe
}

Write-Host "Target: $Target"
if ($targetConfig.sdFolder) { Write-Host "SD pack: $($targetConfig.sdFolder)" }
Write-Host "Merging NERC SD payload into: $sdPath"
Copy-Item -Path (Join-Path $sdSource "*") -Destination $sdPath -Recurse -Force

$injectSimulation = $true
if ($null -ne $config.injectTelemetrySimulation) {
    $injectSimulation = [bool]$config.injectTelemetrySimulation
}

$telemetrySimDestination = Join-Path $sdPath "WIDGETS\NERC_GSkyFD\simulator.lua"
$elrsSimDestination = Join-Path $sdPath "SCRIPTS\LIB\NERC_ELRS_SIM.lua"

if ($injectSimulation) {
    if (-not (Test-Path -LiteralPath $telemetrySimSource -PathType Leaf)) {
        throw "Simulator telemetry backend was not found: $telemetrySimSource"
    }
    if (-not (Test-Path -LiteralPath $elrsSimSource -PathType Leaf)) {
        throw "Simulator ELRS backend was not found: $elrsSimSource"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $telemetrySimDestination) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $elrsSimDestination) -Force | Out-Null
    Copy-Item -LiteralPath $telemetrySimSource -Destination $telemetrySimDestination -Force
    Copy-Item -LiteralPath $elrsSimSource -Destination $elrsSimDestination -Force
    Write-Host "Injected independent telemetry and ELRS simulation backends."
}
else {
    if (Test-Path -LiteralPath $telemetrySimDestination -PathType Leaf) {
        Remove-Item -LiteralPath $telemetrySimDestination -Force
    }
    if (Test-Path -LiteralPath $elrsSimDestination -PathType Leaf) {
        Remove-Item -LiteralPath $elrsSimDestination -Force
    }
    Write-Host "Removed dev simulation backends because injectTelemetrySimulation=false."
}

if ($SyncOnly) {
    Write-Host "Simulator SD sync complete for '$Target'."
    exit 0
}

# IMPORTANT: --sd-path selects the SD asset pack only. Do not pass
# --start-with sd here. That option tells the simulator to load the radio's
# persistent model/radio data from <sd-path>\RADIO\radio.yml, which the normal
# EdgeTX screen-size SD packs do not contain. The Companion profile supplies
# the simulator radio/model data; --sd-path supplies SCRIPTS/WIDGETS/IMAGES/etc.
$arguments = @(
    "--sd-path", ('"' + $sdPath + '"')
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

$process = Start-Process -FilePath $simulatorExe `
    -ArgumentList $arguments `
    -WorkingDirectory (Split-Path -Parent $simulatorExe) `
    -PassThru

Write-Host "EdgeTX simulator started (PID $($process.Id))."
