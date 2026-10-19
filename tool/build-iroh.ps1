# Builds OurNet's iroh binding (vendor/iroh_mobile/rust) for Windows and
# installs it where the app bundles it (app/native) and where iroh_quic finds
# it for `dart test` (its per-user library cache). Ours differs from the
# upstream prebuilt library: it maps router ports (UPnP, NAT-PMP, PCP) and
# keeps n0's address lookup beside the app's (docs/CONNECTIVITY.md).
$ErrorActionPreference = 'Stop'
function cargo { $ErrorActionPreference = 'Continue'; & (Get-Command cargo -CommandType Application | Select-Object -First 1) @args }
$taskRoot = Split-Path $PSScriptRoot -Parent
Push-Location (Join-Path $taskRoot 'vendor/iroh_mobile/rust')
try {
  cargo build --release
  if ($LASTEXITCODE -ne 0) { throw 'iroh binding build failed' }
  $taskLibrary = (Resolve-Path 'target/release/irohdart_ffi.dll').Path
} finally { Pop-Location }
# Skip unchanged copies: a running `dart test` (or an older app build) holds
# the cache's library open, and a no-op build should not fail on it.
function Install-IrohLibrary([string]$Directory) {
  New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  $taskTarget = Join-Path $Directory 'irohdart_ffi.dll'
  if ((Test-Path -LiteralPath $taskTarget) -and
      (Get-FileHash -LiteralPath $taskTarget).Hash -eq (Get-FileHash -LiteralPath $taskLibrary).Hash) { return }
  Copy-Item -LiteralPath $taskLibrary -Destination $taskTarget
}
Install-IrohLibrary (Join-Path $taskRoot 'app/native')
Install-IrohLibrary (Join-Path $env:LOCALAPPDATA 'iroh_quic/v1.0.3/x86_64-pc-windows-msvc')
