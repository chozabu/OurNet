$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
Push-Location (Join-Path $taskRoot 'app')
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed' }
} finally { Pop-Location }
# Our iroh binding, not the upstream prebuilt one (see tool/build-iroh.ps1).
& (Join-Path $PSScriptRoot 'build-iroh.ps1')
Push-Location (Join-Path $taskRoot 'core')
try { dart pub get; if ($LASTEXITCODE -ne 0) { throw 'Core dependencies failed' } }
finally { Pop-Location }
Push-Location (Join-Path $taskRoot 'transport')
try { dart pub get; if ($LASTEXITCODE -ne 0) { throw 'Transport dependencies failed' } }
finally { Pop-Location }
