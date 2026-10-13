param([string]$ReleaseDirectory = '', [string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$release = if ($ReleaseDirectory) { (Resolve-Path -LiteralPath $ReleaseDirectory).Path } else { Join-Path $root 'dist/android' }
$output = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist/releases/android' }
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite package directory: $output" }
$targets = @(
    @{ architecture = 'arm64-v8a'; file = 'tug-android.apk' },
    @{ architecture = 'armeabi-v7a'; file = 'tug-android-arm32.apk' },
    @{ architecture = 'x86_64'; file = 'tug-android-x86_64.apk' }
)
foreach ($required in @($targets.file) + @('manifest.json')) {
    if (!(Test-Path -LiteralPath (Join-Path $release $required) -PathType Leaf)) { throw "Incomplete Release: $required" }
}
$manifest = Get-Content -LiteralPath (Join-Path $release 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.signing -notin @('release keystore; certificate verified', 'local Android debug keystore; not production distribution') -or
    $manifest.signing_certificate_sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'APK manifest mismatch: verified signing metadata is required.'
}
if (@($manifest.artifacts).Count -ne $targets.Count -or
    (@($manifest.architectures | Sort-Object) -join ',') -ne (@($targets.architecture | Sort-Object) -join ',')) {
    throw 'APK manifest mismatch: expected three architecture-specific artifacts.'
}
foreach ($target in $targets) {
    $artifact = @($manifest.artifacts | Where-Object { $_.file -eq $target.file })
    $apk = Join-Path $release $target.file
    $hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($artifact.Count -ne 1 -or $artifact[0].architecture -ne $target.architecture -or
        $artifact[0].signing_certificate_sha256 -cne $manifest.signing_certificate_sha256 -or
        (Get-Item -LiteralPath $apk).Length -ne $artifact[0].bytes -or $hash -ne $artifact[0].sha256) {
        throw "APK manifest mismatch: $($target.file)"
    }
}
$primary = @($manifest.artifacts | Where-Object { $_.file -eq 'tug-android.apk' })[0]
if ($manifest.sha256 -ne $primary.sha256 -or $manifest.bytes -ne $primary.bytes) { throw 'APK manifest mismatch: primary APK.' }
$commit = (git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify source commit.' }
$dirty = [bool](git -C $root status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source status.' }
$version = (python "$PSScriptRoot/component_version.py" android).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Android component version.' }
$assetNames = @(python "$PSScriptRoot/component_version.py" android --assets)
if ($LASTEXITCODE -ne 0 -or $assetNames.Count -ne $targets.Count) { throw 'Cannot resolve Android package filenames.' }
if ($manifest.source_commit -ne $commit -or $manifest.source_dirty -ne $dirty -or $manifest.version -ne $version) {
    throw 'APK manifest does not identify the current source revision, working tree and version.'
}
$repository = if ($env:GITHUB_REPOSITORY) { "https://github.com/$env:GITHUB_REPOSITORY" } else { (git -C $root remote get-url origin).Trim() }
$packagedArtifacts = @(for ($index = 0; $index -lt $targets.Count; $index++) {
    $artifact = @($manifest.artifacts | Where-Object { $_.file -eq $targets[$index].file })[0]
    [ordered]@{
        file = $assetNames[$index]
        architecture = $artifact.architecture
        sha256 = $artifact.sha256
        bytes = $artifact.bytes
        signing_certificate_sha256 = $artifact.signing_certificate_sha256
    }
})
$metadata = [ordered]@{
    component = 'tug-android'
    version = $version
    platform = 'android'
    architectures = $manifest.architectures
    source_commit = $commit
    working_tree_dirty = $dirty
    repository = $repository
    built_at = [DateTime]::UtcNow.ToString('o')
    flutter = $manifest.flutter
    dart = $manifest.dart
    min_sdk = $manifest.min_sdk
    compile_sdk = $manifest.compile_sdk
    target_sdk = $manifest.target_sdk
    signing = $manifest.signing
    signing_certificate_sha256 = $manifest.signing_certificate_sha256
    artifacts = $packagedArtifacts
    apk_sha256 = $primary.sha256
    bytes = $manifest.bytes
    manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $release 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
}
New-Item -ItemType Directory -Path $output | Out-Null
for ($index = 0; $index -lt $targets.Count; $index++) {
    Copy-Item -LiteralPath (Join-Path $release $targets[$index].file) -Destination (Join-Path $output $assetNames[$index])
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'android-source.json') -Encoding utf8
$checksums = foreach ($name in $assetNames + @('android-source.json')) {
    "$((Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash.ToLowerInvariant())  $name"
}
$checksums | Set-Content -LiteralPath (Join-Path $output 'android-sha256.txt') -Encoding ascii
Write-Output "Three Android APKs packaged: $output"
