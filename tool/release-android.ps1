param(
  [string]$Notes,
  [ValidateSet('internal','alpha','beta','production')][string]$Track = 'internal',
  [string]$Key = (Join-Path $env:USERPROFILE '.ournet-signing/play-service-account.json'),
  [switch]$SkipUpload
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
if (!(Test-Path -LiteralPath (Join-Path $taskRoot 'app/android/key.properties'))) {
  throw 'app/android/key.properties is missing; Play rejects debug-signed bundles.'
}
if (!$SkipUpload -and !(Test-Path -LiteralPath $Key)) {
  throw "Service account key not found at $Key. Pass -Key or use -SkipUpload."
}
# The uploader runs from tool/play_upload, so relative paths must be resolved now.
if (!$SkipUpload) { $Key = (Resolve-Path -LiteralPath $Key).Path }
# Play needs a strictly increasing version code; minutes since 2026-01-01 UTC
# always grows and needs no file edits.
$taskVersionCode = [int][Math]::Floor(([DateTime]::UtcNow - [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalMinutes) + 1000
$taskBuild = Get-Date -Format 'yyyyMMdd-HHmmss'
Push-Location (Join-Path $taskRoot 'app')
try {
  flutter build appbundle --release --build-number $taskVersionCode "--dart-define=OURNET_BUILD=$taskBuild"
  if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
} finally { Pop-Location }
$taskBundle = Join-Path $taskRoot 'app/build/app/outputs/bundle/release/app-release.aab'
Write-Host "Built version code $taskVersionCode at $taskBundle"
if ($SkipUpload) { return }
Push-Location (Join-Path $PSScriptRoot 'play_upload')
try {
  $taskArgs = @('run', 'bin/play_upload.dart', '--key', $Key, '--bundle', $taskBundle, '--track', $Track)
  if ($Notes) { $taskArgs += @('--notes', $Notes) }
  dart @taskArgs
  if ($LASTEXITCODE -ne 0) { throw 'Upload to Google Play failed.' }
} finally { Pop-Location }
