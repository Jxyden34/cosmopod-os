[CmdletBinding()]
param(
    [ValidateSet('pi4', 'pi5', 'vm')]
    [string]$Board = 'pi4',

    [string]$Version = '',

    [ValidateSet('auto', 'native', 'container')]
    [string]$Engine = 'auto',

    [switch]$CheckoutOnly
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

Write-Host "Cosmopod OS: board=$Board version=$Version engine=$Engine"
& wsl.exe -d Ubuntu -- bash "$wslProject/scripts/build.sh" $mode --engine $Engine --board $Board --version $Version
if ($LASTEXITCODE -ne 0) {
    throw "Cosmopod OS build failed with exit code $LASTEXITCODE"
}
