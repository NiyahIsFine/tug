$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
$sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
$images = @()
$brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 66, 99, 235))
try {
    foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size, $size)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::White)
            $barWidth = [int][Math]::Round($size * 0.5)
            $strokeWidth = [int][Math]::Round($size * 0.16)
            $letterHeight = [int][Math]::Round($size * 0.56)
            $top = [int][Math]::Floor(($size - $letterHeight) / 2)
            $barLeft = [int][Math]::Floor(($size - $barWidth) / 2)
            $stemLeft = [int][Math]::Floor(($size - $strokeWidth) / 2)
            $graphics.FillRectangle($brush, $barLeft, $top, $barWidth, $strokeWidth)
            $graphics.FillRectangle($brush, $stemLeft, $top, $strokeWidth, $letterHeight)
            $png = [IO.MemoryStream]::new()
            try {
                $bitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
                $images += ,$png.ToArray()
            } finally { $png.Dispose() }
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $brush.Dispose() }

$iconPath = Join-Path $root 'client\windows\assets\tug.ico'
New-Item -ItemType Directory -Path (Split-Path -Parent $iconPath) -Force | Out-Null
$stream = [IO.File]::Create($iconPath)
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($imageIndex = 0; $imageIndex -lt $sizes.Count; $imageIndex++) {
        $dimension = if ($sizes[$imageIndex] -eq 256) { 0 } else { $sizes[$imageIndex] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$imageIndex].Length); $writer.Write([uint32]$offset)
        $offset += $images[$imageIndex].Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image) }
} finally { $writer.Dispose(); $stream.Dispose() }
$runnerIconPath = Join-Path $root 'client\windows\windows\runner\resources\app_icon.ico'
New-Item -ItemType Directory -Path (Split-Path -Parent $runnerIconPath) -Force | Out-Null
Copy-Item -LiteralPath $iconPath -Destination $runnerIconPath
