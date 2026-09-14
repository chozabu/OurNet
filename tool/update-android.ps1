param(
  [string]$Device,
  [switch]$Desktop,
  [ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Profile = 'main',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskAdbCommand = Get-Command adb -ErrorAction SilentlyContinue
$taskAdb = if ($taskAdbCommand) { $taskAdbCommand.Source } else { $null }
if (!$taskAdb) {
  foreach ($taskSdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android/Sdk'))) {
    if ($taskSdk) {
      $taskCandidate = Join-Path $taskSdk 'platform-tools/adb.exe'
      if (Test-Path -LiteralPath $taskCandidate) { $taskAdb = $taskCandidate; break }
    }
  }
}
if (!$taskAdb) { throw 'adb not found. Install Android SDK platform-tools or set ANDROID_HOME.' }
if (!(Get-Command flutter -ErrorAction SilentlyContinue) -and !$SkipBuild) { throw 'Flutter is not on PATH.' }
$taskListing = & $taskAdb devices
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Android devices.' }
$taskDevices = @($taskListing | ForEach-Object {
  if ($_ -match '^(\S+)\s+device\s*$') { $Matches[1] }
})
if ($Device) {
  if ($Device -notin $taskDevices) { throw "Device '$Device' is not ready. Unlock it and accept the USB debugging prompt. Run adb devices for details." }
} elseif ($taskDevices.Count -eq 1) { $Device = $taskDevices[0] }
elseif ($taskDevices.Count -eq 0) { throw 'No authorised Android device found. Connect your phone, enable USB debugging and accept its authorisation prompt.' }
else { throw "Multiple devices found: $($taskDevices -join ', '). Select one with -Device SERIAL." }

$taskApk = Join-Path $taskRoot 'app/build/app/outputs/flutter-apk/app-debug.apk'
if (!$SkipBuild) {
  $taskAbi = (& $taskAdb -s $Device shell getprop ro.product.cpu.abi | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to read the Android CPU architecture.' }
  $taskPlatform = switch ($taskAbi) {
    'arm64-v8a' { 'android-arm64' }
    'armeabi-v7a' { 'android-arm' }
    'x86_64' { 'android-x64' }
    default { throw "Unsupported Android CPU architecture: $taskAbi" }
  }
  Push-Location (Join-Path $taskRoot 'app')
  try {
    flutter build apk --debug --target-platform $taskPlatform "--dart-define=OURNET_BUILD=$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed. The installed app has not been changed.' }
  } finally { Pop-Location }
}
if (!(Test-Path -LiteralPath $taskApk)) { throw 'No debug APK found. Run without -SkipBuild.' }
Write-Host "Updating OurNet on $Device (keeping profile and files)..."
& $taskAdb -s $Device install -r $taskApk
if ($LASTEXITCODE -ne 0) { throw 'Install failed. No uninstall or data reset was attempted. Check the adb error above.' }
& $taskAdb -s $Device shell am start -S -n org.ournet.ournet/.MainActivity
if ($LASTEXITCODE -ne 0) { throw 'Installed successfully, but Android could not launch OurNet.' }
if ($Desktop) {
  if ($SkipBuild) { & (Join-Path $PSScriptRoot 'run.ps1') -Profile $Profile }
  else { & (Join-Path $PSScriptRoot 'run.ps1') -Profile $Profile -Build }
}
Write-Host 'OurNet is ready. On your PC open Profile > Add device; on a new phone choose Connect to my existing profile.'
