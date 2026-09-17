param(
  [string]$Device,
  [switch]$Desktop,
  [switch]$Release,
  [ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Profile = 'main',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell turns native stderr (e.g. Gradle/Kotlin warnings) into
# terminating errors under 'Stop'; native tools report failure via exit code.
function Invoke-Native([scriptblock]$Command) {
  $ErrorActionPreference = 'Continue'
  & $Command
}
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskMode = if ($Release) { 'release' } else { 'debug' }
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
$taskListing = Invoke-Native { & $taskAdb devices }
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Android devices.' }
$taskDevices = @($taskListing | ForEach-Object {
  if ("$_" -match '^(\S+)\s+device\s*$') { $Matches[1] }
})
if ($Device) {
  if ($Device -notin $taskDevices) { throw "Device '$Device' is not ready. Unlock it and accept the USB debugging prompt. Run adb devices for details." }
} elseif ($taskDevices.Count -eq 1) { $Device = $taskDevices[0] }
elseif ($taskDevices.Count -eq 0) { throw 'No authorised Android device found. Connect your phone, enable USB debugging and accept its authorisation prompt.' }
else { throw "Multiple devices found: $($taskDevices -join ', '). Select one with -Device SERIAL." }

$taskApk = Join-Path $taskRoot "app/build/app/outputs/flutter-apk/app-$taskMode.apk"
if (!$SkipBuild) {
  $taskAbi = (Invoke-Native { & $taskAdb -s $Device shell getprop ro.product.cpu.abi } | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to read the Android CPU architecture.' }
  $taskPlatform = switch ($taskAbi) {
    'arm64-v8a' { 'android-arm64' }
    'armeabi-v7a' { 'android-arm' }
    'x86_64' { 'android-x64' }
    default { throw "Unsupported Android CPU architecture: $taskAbi" }
  }
  # Same scheme as release-android.ps1, so a local build can replace a newer
  # Play/release install instead of failing with INSTALL_FAILED_VERSION_DOWNGRADE.
  $taskVersionCode = [int][Math]::Floor(([DateTime]::UtcNow - [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalMinutes) + 1000
  Push-Location (Join-Path $taskRoot 'app')
  try {
    Invoke-Native { flutter build apk "--$taskMode" --target-platform $taskPlatform --build-number $taskVersionCode "--dart-define=OURNET_BUILD=$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed. The installed app has not been changed.' }
  } finally { Pop-Location }
}
if (!(Test-Path -LiteralPath $taskApk)) { throw "No $taskMode APK found. Run without -SkipBuild." }
Write-Host "Updating OurNet ($taskMode) on $Device (keeping profile and files)..."
$taskInstall = (Invoke-Native { & $taskAdb -s $Device install -r $taskApk 2>&1 } | ForEach-Object { "$_" }) -join "`n"
Write-Host $taskInstall
if ($LASTEXITCODE -ne 0) {
  if ($taskInstall -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
    $taskInstaller = (Invoke-Native { & $taskAdb -s $Device shell pm list packages -i org.chozabu.ournet } | Out-String)
    $taskSource = if ($taskInstaller -match 'installer=com\.android\.vending') { 'was installed from Google Play (signed by Play)' } else { 'is signed with a different key' }
    throw "Install failed: the OurNet on the phone $taskSource, so a local $taskMode build cannot update it. Nothing was uninstalled. Either update via Play (release-android.ps1), or back up/export your profile, uninstall OurNet on the phone and rerun."
  }
  throw 'Install failed. No uninstall or data reset was attempted. Check the adb error above.'
}
Invoke-Native { & $taskAdb -s $Device shell am start -S -n org.chozabu.ournet/.MainActivity }
if ($LASTEXITCODE -ne 0) { throw 'Installed successfully, but Android could not launch OurNet.' }
if ($Desktop) {
  $taskRunArgs = @{ Profile = $Profile }
  if (!$SkipBuild) { $taskRunArgs.Build = $true }
  if (!$Release) { $taskRunArgs.Debug = $true }
  & (Join-Path $PSScriptRoot 'run.ps1') @taskRunArgs
}
Write-Host 'OurNet is ready. On your PC open Profile > Add device; on a new phone choose Connect to my existing profile.'
