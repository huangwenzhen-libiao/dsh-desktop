# 独立的终端窗口图标，不依赖或修改上游品牌图形。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconPath = Join-Path $PSScriptRoot '..\app.ico'
$frames = @()
$sizes = @(16, 24, 32, 48, 64, 128, 256)
foreach ($size in $sizes)
{
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(224, 236, 255), $size / 15.0)
    $stream = [IO.MemoryStream]::new()
    try
    {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::FromArgb(42, 62, 112))
        $graphics.DrawLine($pen, $size * 0.22, $size * 0.30, $size * 0.43, $size * 0.49)
        $graphics.DrawLine($pen, $size * 0.43, $size * 0.49, $size * 0.22, $size * 0.68)
        $graphics.DrawLine($pen, $size * 0.53, $size * 0.68, $size * 0.79, $size * 0.68)
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        $frames += ,$stream.ToArray()
    }
    finally
    {
        $stream.Dispose()
        $pen.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

# ICO 目录中按尺寸记录 PNG 帧，供 Windows 在不同缩放比例下选用。
$output = [IO.File]::Create($iconPath)
$writer = [IO.BinaryWriter]::new($output)
try
{
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($index = 0; $index -lt $sizes.Count; $index++)
    {
        $dimension = $sizes[$index] % 256
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$index].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$index].Length
    }
    foreach ($frame in $frames)
    {
        $writer.Write([byte[]]$frame)
    }
}
finally
{
    $writer.Dispose()
    $output.Dispose()
}
