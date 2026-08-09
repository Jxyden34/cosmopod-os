[CmdletBinding()]
param(
    [ValidateSet('pi4', 'pi5', 'vm')]
    [string]$Board = 'pi4',

    [string]$Version = '',

    [ValidateSet('auto', 'native', 'container')]
    [string]$Engine = 'auto',

    [ValidateSet('auto', 'development', 'release')]
    [string]$Channel = 'auto',

    [switch]$CheckoutOnly,

    [switch]$AllowDirty,

    [switch]$ReplaceOutput,

    [switch]$AllowUnconfinedTaskNetwork,

    [ValidatePattern('^https://[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?$')]
    [string]$MenderServerUrl = 'https://kys.dpdns.org'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $Version) {
    $Version = (Get-Content -Raw (Join-Path $projectRoot 'VERSION')).Trim()
}

if ($projectRoot -notmatch '^([A-Za-z]):\\(.*)$') {
    throw "Project must be on a Windows drive or build.sh must be run inside WSL."
}

$drive = $Matches[1].ToLowerInvariant()
$tail = $Matches[2].Replace('\', '/')
$wslProject = "/mnt/$drive/$tail"
$mode = if ($CheckoutOnly) { '--checkout-only' } else { '--build' }
$arguments = @(
    $mode,
    '--engine', $Engine,
    '--channel', $Channel,
    '--board', $Board,
    '--version', $Version,
    '--mender-server-url', $MenderServerUrl
)
if ($AllowDirty) { $arguments += '--allow-dirty' }
if ($ReplaceOutput) { $arguments += '--replace-output' }
if ($AllowUnconfinedTaskNetwork) { $arguments += '--allow-unconfined-task-network' }

Write-Host "Cosmopod OS: board=$Board version=$Version engine=$Engine channel=$Channel mender=$MenderServerUrl"
& wsl.exe -d Ubuntu -- bash "$wslProject/scripts/build.sh" @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Cosmopod OS build failed with exit code $LASTEXITCODE"
}
