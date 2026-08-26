# Smoke test для production APK на connected Android device.
# Usage: подключи Samsung S20 FE через USB с debugging enabled,
# затем:
#   pwsh -File scripts/smoke-release-apk.ps1
#
# Скрипт:
# 1. Confirms device connected
# 2. Uninstalls dev variant (signature mismatch protection)
# 3. Installs production APK
# 4. Verifies versionName/Code
# 5. Starts background logcat capture с filter
# 6. Prints test sequence к screen — ты выполняешь manually
# 7. После твоего ENTER — stops logcat + saves к timestamped file
#
# Если any step fails → script exits с error code и leaves logcat
# на disk для debugging.

$ErrorActionPreference = "Stop"

$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$apkPath = "C:\rodnya-tree-app\build\app\outputs\flutter-apk\app-rustore-release.apk"
$prodPackage = "com.ahjkuio.rodnya_family_app"
$devPackage = "com.ahjkuio.rodnya_family_app.dev"
$logFile = "C:\rodnya-tree-app\scripts\smoke-logcat-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

if (-not (Test-Path $apkPath)) {
    Write-Host "ERROR: APK not found at $apkPath" -ForegroundColor Red
    Write-Host "Rebuild via: flutter build apk --release --flavor rustore" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n=== Step 1: Confirm device connected ===" -ForegroundColor Cyan
$devices = & $adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match "device$" }
if (-not $devices) {
    Write-Host "ERROR: No device connected. Plug USB + enable USB debugging on phone." -ForegroundColor Red
    exit 1
}
Write-Host "Found device(s):" -ForegroundColor Green
$devices | ForEach-Object { Write-Host "  $_" }

Write-Host "`n=== Step 2: Uninstall dev variant (if installed) ===" -ForegroundColor Cyan
& $adb uninstall $devPackage 2>&1 | Out-Null
Write-Host "Done (no-op if dev wasn't installed)" -ForegroundColor Green

Write-Host "`n=== Step 3: Uninstall any prior release (signature safety) ===" -ForegroundColor Cyan
& $adb uninstall $prodPackage 2>&1 | Out-Null
Write-Host "Done (no-op if not installed)" -ForegroundColor Green

Write-Host "`n=== Step 4: Install production APK ===" -ForegroundColor Cyan
Write-Host "APK: $apkPath (130 MB — wait ~30s)" -ForegroundColor Gray
$installResult = & $adb install -r $apkPath 2>&1
if ($installResult -notmatch "Success") {
    Write-Host "ERROR: Install failed" -ForegroundColor Red
    Write-Host $installResult
    exit 1
}
Write-Host "Install OK" -ForegroundColor Green

Write-Host "`n=== Step 5: Verify versionName/Code ===" -ForegroundColor Cyan
$packageInfo = & $adb shell dumpsys package $prodPackage 2>&1
$versionName = ($packageInfo | Select-String -Pattern "versionName=(\S+)").Matches.Groups[1].Value
$versionCode = ($packageInfo | Select-String -Pattern "versionCode=(\d+)").Matches.Groups[1].Value
Write-Host "Installed: versionName=$versionName versionCode=$versionCode" -ForegroundColor Green
if ($versionName -ne "1.0.2") {
    Write-Host "WARNING: expected versionName 1.0.2, got $versionName" -ForegroundColor Yellow
}

Write-Host "`n=== Step 6: Start logcat capture ===" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Gray
& $adb logcat -c 2>&1 | Out-Null
$logcatJob = Start-Job -ScriptBlock {
    param($adbPath, $output)
    & $adbPath logcat | Select-String -Pattern "rodnya|livekit|RodnyaCall|FOREGROUND|ProGuard|R8|AndroidRuntime" -CaseSensitive:$false | ForEach-Object {
        Add-Content -Path $output -Value $_.Line
    }
} -ArgumentList $adb, $logFile
Write-Host "Logcat capture running в background (job ID: $($logcatJob.Id))" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  MANUAL SMOKE TEST — выполни 7 шагов" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host @"

1. Open app on phone → login → home screen renders
2. Start call к peer (browser as peer at https://rodnya-tree.ru либо
   second device)
3. ✅ Bug A check:
   - Lock screen (power button)
   - Wait 30 seconds
   - Peer всё ещё слышит тебя? (talk into mic)
   - Unlock — call still active

4. ✅ Q1 false-positive check:
   - Tap mute → peer перестаёт слышать
   - Tap un-mute → peer снова слышит
   - NO banner «микрофон не подключился» should appear

5. ✅ Bug 2/3 check:
   - Mute button visual matches actual state (icon перечёркнут когда muted)
   - Rapid mute/unmute 5x — no UI flicker, final state matches last tap

6. ✅ Bug 4 check (video call):
   - Start video call (либо switch to video в audio call)
   - PiP appears bottom-right
   - Drag PiP slow — follows finger immediately (не «stuck»)
   - Tap PiP (no drag) — swaps local/remote feed
   - Drag past edge — clamps + snaps к nearest horizontal edge

7. ✅ Bug B check (если BT гарнитура available):
   - Connect BT headset BEFORE start call
   - Permission dialog Bluetooth fires
   - Audio device picker shows «Bluetooth» option
   - Tap BT → audio routes к headset

When done — press ENTER чтобы stop logcat + save log.

"@ -ForegroundColor White

Read-Host "Press ENTER когда smoke complete (любая result — pass либо fail)"

Write-Host "`n=== Step 7: Stop logcat capture ===" -ForegroundColor Cyan
Stop-Job -Job $logcatJob
Remove-Job -Job $logcatJob -Force
Write-Host "Logcat saved: $logFile" -ForegroundColor Green
$lineCount = (Get-Content $logFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
Write-Host "Captured $lineCount lines matching filter" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  RESULT REPORT TO WORKER:" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host @"

Если все 7 pass → upload к RuStore:
  - APK: $apkPath
  - Console: https://console.rustore.ru/
  - Project: ru.rustore.app.2063621085

Если что-то fails → paste logcat output к worker:
  Get-Content $logFile

"@ -ForegroundColor White
