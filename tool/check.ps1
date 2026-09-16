param(
  [switch]$Performance,
  [string]$Device = 'windows'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
foreach ($taskPackage in @('core', 'transport', 'app')) {
  Push-Location (Join-Path $taskRoot $taskPackage)
  try {
    if ($taskPackage -eq 'app') {
      flutter analyze --no-pub
      if ($LASTEXITCODE -ne 0) { throw 'App analysis failed' }
      flutter test --no-pub
    } else {
      dart analyze
      if ($LASTEXITCODE -ne 0) { throw "$taskPackage analysis failed" }
      dart test
    }
    if ($LASTEXITCODE -ne 0) { throw "$taskPackage tests failed" }
  } finally { Pop-Location }
}
if ($Performance) {
  Push-Location (Join-Path $taskRoot 'app')
  try {
    # Android profile builds install as org.chozabu.ournet.profile, separate
    # from the everyday app and its data. Each report is kept by name.
    foreach ($taskTarget in @('responsiveness_test', 'photo_scroll_test', 'note_history_test', 'conversation_history_test')) {
      Remove-Item build/integration_response_data.json -ErrorAction SilentlyContinue
      flutter drive --profile -d $Device --driver=test_driver/performance.dart "--target=integration_test/$taskTarget.dart" --dart-define=PERF_ENFORCE=true
      $taskExit = $LASTEXITCODE
      if (Test-Path build/integration_response_data.json) {
        Copy-Item build/integration_response_data.json "build/$taskTarget-$Device.json" -Force
      }
      if ($taskExit -ne 0) { throw "Performance acceptance check failed: $taskTarget" }
    }
  } finally { Pop-Location }
}
