param(
    [string]$FlutterSdk = '',
    [string]$AndroidSdk = '',
    [switch]$ValidateOnly,
    [ValidateSet('All', 'Dependencies', 'Analyze', 'Test', 'Build')]
    [string]$Stage = 'All',
    [switch]$GradleProfile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$FlutterSdk) { $FlutterSdk = Join-Path $root '.local/flutter-sdk/flutter' }
$flutter = Join-Path $FlutterSdk 'bin/flutter.bat'
$dart = Join-Path $FlutterSdk 'bin/dart.bat'
if (!(Test-Path -LiteralPath $flutter) -or !(Test-Path -LiteralPath $dart)) {
    throw 'Pass -FlutterSdk with a compatible Flutter SDK directory.'
}
function Invoke-Checked([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Tool $($Arguments -join ' ')" }
}
$oldHome = $env:ANDROID_HOME
$oldRoot = $env:ANDROID_SDK_ROOT
$oldPubCache = $env:PUB_CACHE
try {
    if ($ValidateOnly -and $Stage -ne 'All') { throw '-ValidateOnly cannot be combined with a selected stage.' }
    $pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub/Cache' }
    if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($pubCache)) -ne [IO.Path]::GetPathRoot($root)) {
        & (Join-Path $PSScriptRoot 'prepare-android-pub-cache.ps1') -SourceDirectory $pubCache
    }
    if ($AndroidSdk) {
        $AndroidSdk = (Resolve-Path -LiteralPath $AndroidSdk).Path
        $env:ANDROID_HOME = $AndroidSdk
        $env:ANDROID_SDK_ROOT = $AndroidSdk
    }
    Push-Location (Join-Path $root 'client/core')
    try {
        if ($Stage -in @('All', 'Dependencies')) { Invoke-Checked $dart @('pub', 'get', '--enforce-lockfile') }
        if ($Stage -in @('All', 'Analyze')) { Invoke-Checked $dart @('analyze') }
        if ($Stage -in @('All', 'Test')) { Invoke-Checked $dart @('test') }
    } finally { Pop-Location }
    Push-Location (Join-Path $root 'client/android')
    try {
        if ($Stage -in @('All', 'Dependencies')) { Invoke-Checked $flutter @('pub', 'get', '--enforce-lockfile') }
        if ($Stage -in @('All', 'Analyze')) { Invoke-Checked $flutter @('analyze', '--no-pub') }
        if ($Stage -in @('All', 'Test')) { Invoke-Checked $flutter @('test', '--no-pub', '--concurrency=1') }
        if ($ValidateOnly -or $Stage -notin @('All', 'Build')) { return }
        $destination = Join-Path $root 'dist/android'
        $manifestPath = Join-Path $destination 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath }
        $certificateSha256 = $null
        $resolvedSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
        if (!$resolvedSdk) { throw 'Pass -AndroidSdk or set ANDROID_HOME. SDK licenses must already be accepted by the user.' }
        foreach ($required in @('platforms/android-36/android.jar', 'build-tools/36.0.0/apksigner.bat', 'ndk/28.2.13676358/source.properties', 'licenses/android-sdk-license')) {
            if (!(Test-Path -LiteralPath (Join-Path $resolvedSdk $required))) {
                throw "Android toolchain component missing: $required. Install it using Android SDK tools after reviewing licenses."
            }
        }
        $targets = @(
            @{ architecture = 'arm64-v8a'; file = 'tug-android.apk' },
            @{ architecture = 'armeabi-v7a'; file = 'tug-android-arm32.apk' },
            @{ architecture = 'x86_64'; file = 'tug-android-x86_64.apk' }
        )
        foreach ($target in $targets) {
            $apk = Join-Path $root "client/android/build/app/outputs/flutter-apk/app-$($target.architecture)-release.apk"
            if (Test-Path -LiteralPath $apk) { Remove-Item -LiteralPath $apk }
        }
        $wrapper = Join-Path $root 'client/android/android/gradlew.bat'
        $wrapperContents = $null
        if ($GradleProfile) {
            if (!(Test-Path -LiteralPath $wrapper)) {
                $template = Join-Path $FlutterSdk 'bin/cache/artifacts/gradle_wrapper/gradlew.bat'
                if (!(Test-Path -LiteralPath $template)) { throw 'Flutter SDK is missing its Gradle wrapper template.' }
                Copy-Item -LiteralPath $template -Destination $wrapper
            }
            $wrapperContents = [IO.File]::ReadAllText($wrapper)
            if (!$wrapperContents.Contains('org.gradle.wrapper.GradleWrapperMain %CMD_LINE_ARGS%')) {
                throw 'Cannot enable Gradle profile on the generated Windows wrapper.'
            }
            [IO.File]::WriteAllText($wrapper, $wrapperContents.Replace(
                'org.gradle.wrapper.GradleWrapperMain %CMD_LINE_ARGS%',
                'org.gradle.wrapper.GradleWrapperMain --profile %CMD_LINE_ARGS%'
            ))
        }
        try {
            Invoke-Checked $flutter @('build', 'apk', '--release', '--no-pub', '--split-per-abi', '--target-platform=android-arm,android-arm64,android-x64')
        } finally {
            if ($null -ne $wrapperContents) { [IO.File]::WriteAllText($wrapper, $wrapperContents) }
        }
        $apksigner = Join-Path $resolvedSdk 'build-tools/36.0.0/apksigner.bat'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $artifacts = @(foreach ($target in $targets) {
            $apk = Join-Path $root "client/android/build/app/outputs/flutter-apk/app-$($target.architecture)-release.apk"
            if (!(Test-Path -LiteralPath $apk)) { throw "Release build returned without $($target.architecture) APK." }
            $archive = [IO.Compression.ZipFile]::OpenRead($apk)
            try {
                $architectures = @($archive.Entries.FullName | Where-Object { $_ -match '^lib/[^/]+/[^/]+\.so$' } |
                    ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
                if ($architectures.Count -ne 1 -or $architectures[0] -ne $target.architecture) {
                    throw "APK architecture mismatch: $($target.file)"
                }
            } finally { $archive.Dispose() }
            $verification = @(Invoke-Checked $apksigner @('verify', '--verbose', '--print-certs', $apk))
            $signerCertificates = @($verification | Select-String '^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)\s*$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value.Replace(':', '').ToLowerInvariant() })
            if ($signerCertificates.Count -ne 1 -or $signerCertificates[0] -notmatch '^[0-9a-f]{64}$') {
                throw "APK signing certificate missing or invalid: $($target.file)"
            }
            if ($null -eq $certificateSha256) { $certificateSha256 = $signerCertificates[0] }
            if ($signerCertificates[0] -ne $certificateSha256) {
                throw "APK signing certificate mismatch: $($target.file)"
            }
            $exported = Join-Path $destination $target.file
            Copy-Item -LiteralPath $apk -Destination $exported -Force
            [ordered]@{
                file = $target.file
                architecture = $target.architecture
                sha256 = (Get-FileHash -LiteralPath $exported -Algorithm SHA256).Hash.ToLowerInvariant()
                bytes = (Get-Item -LiteralPath $exported).Length
                signing_certificate_sha256 = $certificateSha256
            }
        })
        $artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" } |
            Set-Content -LiteralPath (Join-Path $destination 'SHA256SUMS') -Encoding ascii
        $source = (& git -C $root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source Git revision.' }
        $dirty = [bool](& git -C $root status --porcelain --untracked-files=normal)
        $toolchain = (& $flutter --version --machine | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot identify Flutter toolchain.' }
        [ordered]@{
            stage = 'prototype-baseline-not-final-delivery'
            source_commit = $source
            source_dirty = $dirty
            version = ((Get-Content -LiteralPath 'pubspec.yaml' | Select-String '^version:\s*(\S+)').Matches.Groups[1].Value)
            flutter = $toolchain.flutterVersion
            dart = $toolchain.dartSdkVersion
            min_sdk = 24
            compile_sdk = 36
            target_sdk = 36
            architectures = @($targets.architecture)
            artifacts = $artifacts
            signing = 'local Android debug keystore; not production distribution'
            signing_certificate_sha256 = $certificateSha256
            sha256 = $artifacts[0].sha256
            bytes = $artifacts[0].bytes
            device_installation_verified = $false
            resource_baseline_verified = $false
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        Write-Output "Three verified Release APKs exported: $destination"
    } finally { Pop-Location }
} finally {
    $env:ANDROID_HOME = $oldHome
    $env:ANDROID_SDK_ROOT = $oldRoot
    $env:PUB_CACHE = $oldPubCache
}
