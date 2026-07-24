[CmdletBinding()]
param(
    [ValidateSet('all', 'iso', 'qcow2')]
    [string]$Media = 'all',

    [ValidateSet('auto', 'development', 'release')]
    [string]$Channel = 'auto',

    [string]$Version = '',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Distribution = 'Ubuntu',

    [ValidateRange(10, 9999)]
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $Version) {
    $Version = (Get-Content -Raw (Join-Path $projectRoot 'VERSION')).Trim()
}

if ($projectRoot -notmatch '^([A-Za-z]):\\(.*)$') {
    throw 'Project must be on a Windows drive or smoke-vm.sh must run inside WSL.'
}

$drive = $Matches[1].ToLowerInvariant()
$tail = $Matches[2].Replace('\', '/')
$wslProject = "/mnt/$drive/$tail"

Write-Host "Cosmopod VM smoke test: media=$Media channel=$Channel version=$Version distro=$Distribution timeout=$TimeoutSeconds"
& wsl.exe -d $Distribution -- bash "$wslProject/scripts/smoke-vm.sh" `
    --media $Media --channel $Channel --version $Version --timeout $TimeoutSeconds
if ($LASTEXITCODE -ne 0) {
    throw "Cosmopod VM smoke test failed with exit code $LASTEXITCODE"
}
