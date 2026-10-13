param([string]$ReleaseDirectory = '', [string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$release = if ($ReleaseDirectory) { (Resolve-Path -LiteralPath $ReleaseDirectory).Path } else { Join-Path $root 'dist\windows-x64' }
$output = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist\releases\windows' }
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite package directory: $output" }
foreach ($required in @('tug.exe', 'runtime\tug-ui.exe', 'runtime\tug-receiver.exe', 'runtime\flutter_windows.dll', 'runtime\flutter_local_notifications_windows.dll', 'runtime\data\app.so', 'runtime\data\icudtl.dat', 'runtime\data\flutter_assets\assets\tug.ico', 'manifest.json')) {
    if (!(Test-Path -LiteralPath (Join-Path $release $required) -PathType Leaf)) { throw "Incomplete Release: $required" }
}
$manifest = @(Get-Content -LiteralPath (Join-Path $release 'manifest.json') -Raw | ConvertFrom-Json)
$verifiedPaths = @{}
foreach ($entry in $manifest) {
    $path = [IO.Path]::GetFullPath((Join-Path $release $entry.path))
    if (!$path.StartsWith($release + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escapes Release directory.' }
    if ($verifiedPaths.ContainsKey($path) -or $entry.path -eq 'manifest.json') { throw 'Duplicate or self-referencing manifest path.' }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw "Manifest mismatch: $($entry.path)" }
    $verifiedPaths[$path] = $true
}
$files = @(Get-ChildItem -LiteralPath $release -Recurse -File)
foreach ($file in $files) {
    if ($file.Name -ne 'manifest.json' -and !$verifiedPaths.ContainsKey($file.FullName)) { throw "File absent from manifest: $($file.Name)" }
}
$commit = (git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify source commit.' }
$dirty = [bool](git -C $root status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source status.' }
$version = (python "$PSScriptRoot/component_version.py" windows).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Windows component version.' }
$archiveName = (python "$PSScriptRoot/component_version.py" windows --assets).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Windows package filename.' }
$repository = if ($env:GITHUB_REPOSITORY) { "https://github.com/$env:GITHUB_REPOSITORY" } else { (git -C $root remote get-url origin).Trim() }
$metadata = [ordered]@{ component = 'tug-windows'; version = $version; platform = 'windows/x64'; source_commit = $commit; working_tree_dirty = $dirty; repository = $repository; built_at = [DateTime]::UtcNow.ToString('o'); manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $release 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() }
New-Item -ItemType Directory -Path $output | Out-Null
$metadataPath = Join-Path $output 'windows-source.json'
$metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding utf8
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archivePath = Join-Path $output $archiveName
$archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($release.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, "tug-windows-x64/$relative", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $metadataPath, 'tug-windows-x64/source.json', [IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally { $archive.Dispose() }
$checksums = foreach ($name in @($archiveName, 'windows-source.json')) {
    "$((Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash.ToLowerInvariant())  $name"
}
$checksums | Set-Content -LiteralPath (Join-Path $output 'windows-sha256.txt') -Encoding ascii
Write-Output "Windows package: $archivePath"
