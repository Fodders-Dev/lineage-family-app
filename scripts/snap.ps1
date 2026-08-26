param([int]$W = 520)
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { $adb = "adb" }
& $adb shell screencap -p /sdcard/_snap.png | Out-Null
& $adb pull /sdcard/_snap.png C:\rodnya-tree-app\_snap_full.png 2>&1 | Out-Null
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile("C:\rodnya-tree-app\_snap_full.png")
$dw = $img.Width; $dh = $img.Height
$h = [int]($dh * $W / $dw)
$bmp = New-Object System.Drawing.Bitmap $W, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($img, 0, 0, $W, $h)
$bmp.Save("C:\rodnya-tree-app\_snap.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $img.Dispose()
"device ${dw}x${dh} | scale $([math]::Round($dw/$W,3)) | snap ${W}x${h}"