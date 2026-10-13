$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
$densities = [ordered]@{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
$fontFamily = [Drawing.FontFamily]::new('Segoe UI')
$brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 66, 99, 235))
try {
    foreach ($density in $densities.GetEnumerator()) {
        $size = $density.Value
        $renderSize = $size * 4
        $bitmap = [Drawing.Bitmap]::new($renderSize, $renderSize)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $path = [Drawing.Drawing2D.GraphicsPath]::new()
        $transform = [Drawing.Drawing2D.Matrix]::new()
        try {
            $graphics.Clear([Drawing.Color]::White)
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $path.AddString('Tug', $fontFamily, [int][Drawing.FontStyle]::Bold, $renderSize,
                [Drawing.PointF]::new(0, 0), [Drawing.StringFormat]::GenericTypographic)
            $bounds = $path.GetBounds()
            $scale = [single][Math]::Min($renderSize * 0.74 / $bounds.Width, $renderSize * 0.38 / $bounds.Height)
            $offsetX = [single](($renderSize - $bounds.Width * $scale) / 2 - $bounds.X * $scale)
            $offsetY = [single](($renderSize - $bounds.Height * $scale) / 2 - $bounds.Y * $scale)
            $transform.Scale($scale, $scale)
            $transform.Translate($offsetX, $offsetY, [Drawing.Drawing2D.MatrixOrder]::Append)
            $path.Transform($transform)
            $graphics.FillPath($brush, $path)
            $output = [Drawing.Bitmap]::new($size, $size)
            $outputGraphics = [Drawing.Graphics]::FromImage($output)
            try {
                $outputGraphics.Clear([Drawing.Color]::White)
                $outputGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $outputGraphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $outputGraphics.DrawImage($bitmap, [Drawing.Rectangle]::new(0, 0, $size, $size))
                $iconPath = Join-Path $root "client\android\android\app\src\main\res\mipmap-$($density.Key)\ic_launcher.png"
                New-Item -ItemType Directory -Path (Split-Path -Parent $iconPath) -Force | Out-Null
                $output.Save($iconPath, [Drawing.Imaging.ImageFormat]::Png)
            } finally { $outputGraphics.Dispose(); $output.Dispose() }
        } finally { $transform.Dispose(); $path.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $brush.Dispose(); $fontFamily.Dispose() }
