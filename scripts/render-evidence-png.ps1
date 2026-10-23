#Requires -Version 7
<#
.SYNOPSIS
  Renders captured drill logs (docs/evidence/*.txt) to terminal-style PNGs.

.DESCRIPTION
  Windows only (System.Drawing/GDI+). Each <name>.txt becomes <name>.png next
  to it. Masks 12-digit account IDs, ARNs and security group IDs again before
  drawing, as a second line of defence. Colours: "$ " commands yellow, "::: "
  script markers cyan, "non-200: 0" / PASS / "200:" green, anything with a
  non-zero non-200 count, "000" or FAIL red.

.EXAMPLE
  pwsh scripts/render-evidence-png.ps1
  pwsh scripts/render-evidence-png.ps1 -Path docs/evidence/drill-1-hpa.txt
#>
param(
  [string[]]$Path = (Get-ChildItem (Join-Path $PSScriptRoot '../docs/evidence') -Filter '*.txt').FullName,
  [int]$FontSize = 13
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-Mask([string]$line) {
  $line -replace '\d{12}', '<account>' -replace 'arn:aws:[^\s",]+', '<arn>' -replace 'sg-[0-9a-f]{6,}', '<sg>'
}

function Get-LineBrush([string]$line) {
  # Case-sensitive (-cmatch): k6's "http_req_failed: 0.00%" must not turn red.
  if ($line -cmatch 'non-200: [1-9]|^\s+000:|non-200: 000|FAIL|Warning|error when evicting') { return [System.Drawing.Brushes]::IndianRed }
  if ($line -match '^\$ ') { return [System.Drawing.Brushes]::Khaki }
  if ($line -match '^:::|^---') { return [System.Drawing.Brushes]::SkyBlue }
  if ($line -match '^#') { return [System.Drawing.Brushes]::DarkGray }
  if ($line -cmatch 'non-200: 0|PASS|^\s+200:|✓|SUCCESS|successfully rolled out|rate=0\.00%|0 out of') { return [System.Drawing.Brushes]::LightGreen }
  return [System.Drawing.Brushes]::Gainsboro
}

foreach ($file in $Path) {
  $lines = @(Get-Content -LiteralPath $file -Encoding utf8 | ForEach-Object { Get-Mask ($_ -replace "`t", '    ') })
  $font = [System.Drawing.Font]::new('Consolas', $FontSize, [System.Drawing.GraphicsUnit]::Pixel)
  $probe = [System.Drawing.Bitmap]::new(1, 1)
  $g = [System.Drawing.Graphics]::FromImage($probe)
  $fmt = [System.Drawing.StringFormat]::GenericTypographic
  $charW = $g.MeasureString('M' * 100, $font, [System.Drawing.PointF]::Empty, $fmt).Width / 100
  $g.Dispose(); $probe.Dispose()

  $lineH = [int][Math]::Ceiling($FontSize * 1.35)
  $pad = 16; $bar = 28
  $cols = ($lines | Measure-Object -Property Length -Maximum).Maximum
  $width = [int]([Math]::Ceiling($cols * $charW) + 2 * $pad)
  $width = [Math]::Max($width, 480)
  $height = $bar + $pad + $lines.Count * $lineH + $pad

  $bmp = [System.Drawing.Bitmap]::new($width, $height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear([System.Drawing.Color]::FromArgb(30, 30, 30))
  # Title bar with the file name, like a terminal window.
  $g.FillRectangle([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 55, 60)), 0, 0, $width, $bar)
  $dots = @([System.Drawing.Color]::FromArgb(255, 95, 86), [System.Drawing.Color]::FromArgb(255, 189, 46), [System.Drawing.Color]::FromArgb(39, 201, 63))
  for ($i = 0; $i -lt 3; $i++) { $g.FillEllipse([System.Drawing.SolidBrush]::new($dots[$i]), 10 + $i * 18, 8, 12, 12) }
  $g.DrawString((Split-Path $file -Leaf), $font, [System.Drawing.Brushes]::Silver, 70, 7, $fmt)

  $y = $bar + $pad
  foreach ($line in $lines) {
    $g.DrawString($line, $font, (Get-LineBrush $line), $pad, $y, $fmt)
    $y += $lineH
  }
  $out = [IO.Path]::ChangeExtension($file, '.png')
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose(); $font.Dispose()
  Write-Host "rendered $out ($width x $height)"
}
