param([string]$FlutterRoot = '', [string]$CMakePath = '', [string]$VisualStudioPath = '', [string]$OutputDirectory = '', [switch]$ConfigureOnly, [switch]$NoPub)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$FlutterRoot) { $FlutterRoot = Join-Path $root '.local\flutter-sdk\flutter' }
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Pass -FlutterRoot pointing to a Flutter SDK.' }
if ($NoPub -and !(Test-Path -LiteralPath (Join-Path $root 'client/windows/.dart_tool/package_config.json'))) {
    throw '-NoPub requires installed Windows dependencies. Run flutter pub get --enforce-lockfile in client/windows first.'
}
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$target = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist\windows-x64' }
if (!$ConfigureOnly -and (Test-Path -LiteralPath $target)) { throw "Output directory already exists; archive it before delivering a new complete directory: $target" }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer/vswhere is required to identify the MSVC installation.' }
$instances = @((& $vswhere -products '*' -all -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8) | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'vswhere failed.' }
if ($VisualStudioPath) {
    $instance = $instances | Where-Object { $_.installationPath -eq $VisualStudioPath } | Select-Object -First 1
} else {
    $instance = $instances | Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
}
if (!$instance -or !$instance.isComplete) { throw 'VS 2022 IDE or Build Tools with MSVC x64/x86 is required.' }
$VisualStudioPath = $instance.installationPath
$bundledCMake = Join-Path $VisualStudioPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$externalCMake = $CMakePath -or !(Test-Path -LiteralPath $bundledCMake)
if ($externalCMake -and !$CMakePath) {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if (!$command) { throw 'Pass -CMakePath or install CMake tools for Windows in the selected Visual Studio instance.' }
    $CMakePath = $command.Source
}
function Invoke-Checked([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Build command failed: $Tool $($Arguments -join ' ')" }
}
Push-Location (Join-Path $root 'client\windows')
try {
    if (!$NoPub) { Invoke-Checked $flutter @('pub', 'get', '--enforce-lockfile') }
    if (!$externalCMake) {
        $arguments = @('build', 'windows', '--release', '--no-pub')
        if ($ConfigureOnly) { $arguments += '--config-only' }
        Invoke-Checked $flutter $arguments
    } else {
        if (!(Test-Path -LiteralPath $CMakePath)) { throw 'The selected CMake executable does not exist.' }
        $versionText = (Get-Content -LiteralPath 'pubspec.yaml' | Select-String '^version:\s*(\d+)\.(\d+)\.(\d+)(?:-[-\w.]+)?(?:\+(\d+))?\s*$').Matches
        if ($versionText.Count -ne 1) { throw 'Expected one semantic version in pubspec.yaml.' }
        $match = $versionText[0]
        $buildNumber = if ($match.Groups[4].Success) { $match.Groups[4].Value } else { '0' }
        $projectPath = (Get-Location).Path.Replace('\', '/')
        $sdkPath = (Resolve-Path -LiteralPath $FlutterRoot).Path.Replace('\', '/')
        foreach ($path in @($projectPath, $sdkPath)) {
            if ($path.Contains('"') -or $path.Contains('$') -or $path.Contains(';')) { throw 'CMake configuration paths must not contain quotes, dollar signs, or semicolons.' }
        }
        $version = $match.Value.Substring($match.Value.IndexOf(':') + 1).Trim()
        $buildName = $match.Groups[1..3].Value -join '.'
        $configuration = @"
file(TO_CMAKE_PATH "$sdkPath" FLUTTER_ROOT)
file(TO_CMAKE_PATH "$projectPath" PROJECT_DIR)
set(FLUTTER_VERSION "$version" PARENT_SCOPE)
set(FLUTTER_VERSION_MAJOR $($match.Groups[1].Value) PARENT_SCOPE)
set(FLUTTER_VERSION_MINOR $($match.Groups[2].Value) PARENT_SCOPE)
set(FLUTTER_VERSION_PATCH $($match.Groups[3].Value) PARENT_SCOPE)
set(FLUTTER_VERSION_BUILD $buildNumber PARENT_SCOPE)
list(APPEND FLUTTER_TOOL_ENVIRONMENT
  "FLUTTER_ROOT=$sdkPath"
  "PROJECT_DIR=$projectPath"
  "FLUTTER_EPHEMERAL_DIR=$projectPath/windows/flutter/ephemeral"
  "FLUTTER_TARGET=lib/main.dart"
  "BUILD_NAME=$buildName"
  "BUILD_NUMBER=$buildNumber"
  "DART_OBFUSCATION=false"
  "TRACK_WIDGET_CREATION=false"
  "TREE_SHAKE_ICONS=true"
  "PACKAGE_CONFIG=$projectPath/.dart_tool/package_config.json"
)
"@
        New-Item -ItemType Directory -Path 'windows\flutter\ephemeral' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectPath 'windows/flutter/ephemeral/generated_config.cmake'), $configuration, [Text.UTF8Encoding]::new($false))
        Write-Output "Using $($instance.displayName) at $VisualStudioPath with standalone CMake $CMakePath"
        Invoke-Checked $CMakePath @('-S', 'windows', '-B', 'build/windows/x64', '-G', 'Visual Studio 17 2022', '-A', 'x64', "-DCMAKE_GENERATOR_INSTANCE=$VisualStudioPath", '-DFLUTTER_TARGET_PLATFORM=windows-x64', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
        if (!$ConfigureOnly) {
            Invoke-Checked $CMakePath @('--build', 'build/windows/x64', '--config', 'Release', '--target', 'INSTALL', '--parallel', '4')
        }
    }
} finally { Pop-Location }
if ($ConfigureOnly) { Write-Output 'Windows x64 CMake configuration completed; no Release directory delivered.'; return }
$source = Join-Path $root 'client\windows\build\windows\x64\runner\Release'
foreach ($required in @('tug.exe', 'runtime\tug-ui.exe', 'runtime\tug-receiver.exe', 'runtime\flutter_windows.dll', 'runtime\flutter_local_notifications_windows.dll', 'runtime\data\app.so', 'runtime\data\icudtl.dat', 'runtime\data\flutter_assets\assets\tug.ico')) {
    if (!(Test-Path -LiteralPath (Join-Path $source $required))) { throw "Incomplete Release: missing $required" }
}
New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'tug.exe'), (Join-Path $source 'runtime') -Destination $target -Recurse
$files = Get-ChildItem -LiteralPath $target -File -Recurse
$manifest = foreach ($file in $files) {
    [ordered]@{ path = $file.FullName.Substring($target.Length + 1); bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower() }
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $target 'manifest.json') -Encoding utf8
Write-Output "Complete Release directory: $target"
