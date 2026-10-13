param(
    [Parameter(Mandatory = $true)][string]$Adb,
    [Parameter(Mandatory = $true)][string]$Serial,
    [ValidateRange(1, 1440)][int]$Minutes = 30,
    [ValidateRange(30, 3600)][int]$IntervalSeconds = 60,
    [ValidateRange(0, 3600)][int]$WarmupSeconds = 120,
    [ValidateSet('idle-receiving', 'diagnostic')][string]$Scenario = 'idle-receiving',
    [ValidateSet('physical', 'emulator', 'unknown')][string]$DeviceKind = 'unknown',
    [string]$Python = 'python',
    [string]$OutputDirectory = '',
    [string]$Package = 'dev.tug.tug_android'
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$') { throw 'Invalid Android package name.' }
if (!(Test-Path -LiteralPath $Adb)) { throw 'The adb executable does not exist.' }
$root = Split-Path -Parent $PSScriptRoot
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $root ('.local/android-resource-samples/' + [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}
$arguments = @((Join-Path $PSScriptRoot 'android_resources.py'), 'collect', '--adb', $Adb, '--serial', $Serial,
    '--package', $Package, '--output', $OutputDirectory, '--minutes', $Minutes, '--interval', $IntervalSeconds,
    '--warmup', $WarmupSeconds, '--scenario', $Scenario, '--device-kind', $DeviceKind)
& $Python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Android resource collection failed; inspect preserved raw evidence and summary if present.' }
Write-Output "Exploratory evidence (not final acceptance): $OutputDirectory"
