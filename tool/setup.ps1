$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
Push-Location (Join-Path $taskRoot 'app')
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed' }
  dart run iroh_quic:setup --force
  if ($LASTEXITCODE -ne 0) { throw 'Signed native library installation failed' }
  $taskLibrary = Join-Path $env:LOCALAPPDATA 'iroh_quic/v1.0.3/x86_64-pc-windows-msvc/irohdart_ffi.dll'
  New-Item -ItemType Directory -Force -Path native | Out-Null
  Copy-Item -LiteralPath $taskLibrary -Destination native/irohdart_ffi.dll
} finally { Pop-Location }
Push-Location (Join-Path $taskRoot 'core')
try { dart pub get; if ($LASTEXITCODE -ne 0) { throw 'Core dependencies failed' } }
finally { Pop-Location }
Push-Location (Join-Path $taskRoot 'transport')
try { dart pub get; if ($LASTEXITCODE -ne 0) { throw 'Transport dependencies failed' } }
finally { Pop-Location }
