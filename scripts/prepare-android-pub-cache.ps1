param([string]$SourceDirectory = '', [string]$DestinationDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$SourceDirectory) {
    $SourceDirectory = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub/Cache' }
}
if (!$DestinationDirectory) { $DestinationDirectory = Join-Path $root '.local/pub-cache' }
$source = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$destination = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ([IO.Path]::GetPathRoot($destination) -ne [IO.Path]::GetPathRoot($root)) {
    throw 'The Pub cache destination must be on the project drive.'
}
if ($source -ne $destination) {
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($destination.StartsWith("$source$separator", [StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith("$destination$separator", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Pub cache source and destination must not contain one another.'
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    if (Test-Path -LiteralPath $source -PathType Container) {
        foreach ($entry in Get-ChildItem -LiteralPath $source -Force) {
            Copy-Item -LiteralPath $entry.FullName -Destination $destination -Recurse -Force
        }
    }
} else {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}
$env:PUB_CACHE = $destination
Write-Output "Android Pub cache: $destination"
