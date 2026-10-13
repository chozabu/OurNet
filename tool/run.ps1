param(
  [ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Profile = 'main',
  [switch]$Build,
  [switch]$Debug
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
# Match the full executable path so Store installs and other checkouts stay open.
function Close-LocalOurNet([string]$Executable) {
  foreach ($taskProcess in @(Get-Process -Name ournet -ErrorAction SilentlyContinue)) {
    if (![string]::Equals($taskProcess.Path, $Executable, [StringComparison]::OrdinalIgnoreCase)) { continue }
    # Give the window a chance to shut down normally. Tray-only windows may not
    # exit on WM_CLOSE; terminate them after a bounded wait to release DLL locks.
    $taskClosing = $taskProcess.CloseMainWindow()
    if (!$taskClosing -or !$taskProcess.WaitForExit(3000)) {
      if (!$taskProcess.HasExited) { $taskProcess.Kill() }
      if (!$taskProcess.WaitForExit(5000)) { throw 'OurNet did not exit before the update' }
    }
  }
}
$taskConfiguration = if ($Debug) { 'Debug' } else { 'Release' }
$taskExe=Join-Path $taskRoot "app/build/windows/x64/runner/$taskConfiguration/ournet.exe"
if (!$Debug) {
  $taskLatest=Join-Path $taskRoot 'dist/latest-windows.txt'
  if ($Build -or !(Test-Path -LiteralPath $taskLatest)) { & (Join-Path $PSScriptRoot 'package.ps1') }
  if (Test-Path -LiteralPath $taskLatest) {
    $taskPackage=[IO.Path]::GetFullPath((Join-Path $taskRoot (Get-Content -Raw -LiteralPath $taskLatest).Trim()))
    $taskDist=[IO.Path]::GetFullPath((Join-Path $taskRoot 'dist'))
    $taskLocal=Join-Path $taskDist 'windows-local'
    # /MIR removes stale packaged files: only use it inside this fixed generated
    # destination, with a separate, existing package under this repo's dist.
    if (!(Split-Path $taskPackage -Parent).Equals($taskDist, [StringComparison]::OrdinalIgnoreCase) -or
        $taskPackage.Equals($taskLocal, [StringComparison]::OrdinalIgnoreCase) -or
        !(Test-Path -LiteralPath (Join-Path $taskPackage 'ournet.exe'))) {
      throw 'latest-windows.txt must point to a packaged build in dist'
    }
    $taskExe=Join-Path $taskLocal 'ournet.exe'
    $taskInstalled=Join-Path $taskLocal '.package-source'
    if (!(Test-Path -LiteralPath $taskExe) -or !(Test-Path -LiteralPath $taskInstalled) -or
        (Get-Content -Raw -LiteralPath $taskInstalled).Trim() -ne $taskPackage) {
      Close-LocalOurNet $taskExe
      robocopy $taskPackage $taskLocal /MIR /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
      if ($LASTEXITCODE -ge 8) { throw 'Local Windows package update failed' }
      $taskPackage | Set-Content -LiteralPath $taskInstalled
    }
  }
}
if(($Debug -and $Build) -or !(Test-Path -LiteralPath $taskExe)) {
  Close-LocalOurNet $taskExe
  Push-Location (Join-Path $taskRoot 'app')
  try {
    # Native stderr (build warnings) must not trip 'Stop'; the exit code decides.
    $ErrorActionPreference='Continue'
    if ($Debug) { flutter build windows --debug } else { flutter build windows --release --no-tree-shake-icons }
    $ErrorActionPreference='Stop'
    if($LASTEXITCODE -ne 0){throw 'Build failed'}
  }
  finally {Pop-Location}
}
# This is the interactive GUI executable, not a background helper. SW_HIDE in
# STARTUPINFO overrides Flutter's first ShowWindow call and hides the app.
Start-Process -FilePath $taskExe -ArgumentList "--profile=$Profile" -WorkingDirectory (Split-Path $taskExe -Parent) -WindowStyle Normal
