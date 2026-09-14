param(
  [Parameter(Mandatory = $true)][string]$Device,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskApp = Join-Path $taskRoot 'app'
$taskPackage = 'org.ournet.ournet.profile'
if (-not $SkipBuild) {
  Push-Location (Join-Path $taskApp 'android')
  try {
    .\gradlew.bat :app:assembleProfile :app:assembleProfileAndroidTest -Ptarget-platform=android-arm64 --console=plain
    if ($LASTEXITCODE -ne 0) { throw 'Android widget test build failed' }
  } finally { Pop-Location }
}
adb -s $Device install -r (Join-Path $taskApp 'build/app/outputs/apk/profile/app-profile.apk')
if ($LASTEXITCODE -ne 0) { throw 'Profile APK installation failed' }
adb -s $Device install -r (Join-Path $taskApp 'build/app/outputs/apk/androidTest/profile/app-profile-androidTest.apk')
if ($LASTEXITCODE -ne 0) { throw 'Instrumentation APK installation failed' }
try {
  foreach ($taskMethod in @('nativeOutboxResizePrivacyAndDeepLinks', 'boardListsNotesAndHidesContents', 'staleProfileAndQueueLimit', 'persistColdFixture', 'readColdFixture')) {
    # Every instrumentation invocation is a new process; explicitly stop the
    # profile package between the disk persistence and cold-read checks too.
    adb -s $Device shell am force-stop $taskPackage
    # Android clears the host grant on force-stop.
    adb -s $Device shell appwidget grantbind --package $taskPackage --user current
    $taskOutput = adb -s $Device shell am instrument -w -r -e class "org.ournet.ournet.NoteWidgetTest#$taskMethod" "$taskPackage.test/androidx.test.runner.AndroidJUnitRunner" 2>&1
    $taskOutput
    if ($LASTEXITCODE -ne 0 -or ($taskOutput -join "`n") -notmatch 'OK \(1 test\)') {
      throw "Android widget check failed: $taskMethod"
    }
  }
} finally {
  adb -s $Device shell appwidget revokebind --package $taskPackage --user current
}
