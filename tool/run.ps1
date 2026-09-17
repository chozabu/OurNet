param(
  [ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Profile = 'main',
  [switch]$Build,
  [switch]$Debug
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskConfiguration = if ($Debug) { 'Debug' } else { 'Release' }
$taskExe=Join-Path $taskRoot "app/build/windows/x64/runner/$taskConfiguration/ournet.exe"
if (!$Debug) {
  $taskLatest=Join-Path $taskRoot 'dist/latest-windows.txt'
  if ($Build -or !(Test-Path -LiteralPath $taskLatest)) { & (Join-Path $PSScriptRoot 'package.ps1') }
  if (Test-Path -LiteralPath $taskLatest) {
    $taskExe=Join-Path (Join-Path $taskRoot (Get-Content -Raw -LiteralPath $taskLatest).Trim()) 'ournet.exe'
  }
}
if(($Debug -and $Build) -or !(Test-Path -LiteralPath $taskExe)) {
  Push-Location (Join-Path $taskRoot 'app')
  try {
    # Native stderr (build warnings) must not trip 'Stop'; the exit code decides.
    $ErrorActionPreference='Continue'
    if ($Debug) { flutter build windows --debug } else { flutter build windows --release }
    $ErrorActionPreference='Stop'
    if($LASTEXITCODE -ne 0){throw 'Build failed'}
  }
  finally {Pop-Location}
}
# This is the interactive GUI executable, not a background helper. SW_HIDE in
# STARTUPINFO overrides Flutter's first ShowWindow call and hides the app.
Start-Process -FilePath $taskExe -ArgumentList "--profile=$Profile" -WorkingDirectory (Split-Path $taskExe -Parent) -WindowStyle Normal
