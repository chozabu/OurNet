param([switch]$Android)
$ErrorActionPreference = 'Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskBuild=Get-Date -Format 'yyyyMMdd-HHmmss'
$taskOutput=Join-Path $taskRoot "dist/OurNet-0.2.0-$taskBuild"
$taskStage=Join-Path $taskRoot 'build/package-source'
# Build a source snapshot so running app binaries are never overwritten.
foreach($taskComponent in @('app','core','transport','vendor/iroh_mobile')) {
  $taskSource=Join-Path $taskRoot $taskComponent
  $taskDestination=Join-Path $taskStage $taskComponent
  New-Item -ItemType Directory -Force -Path $taskDestination | Out-Null
  # Refresh source-only folders while retaining native build caches. These are
  # generated copies, never the working repository or profile data.
  foreach($taskSourceFolder in @('lib','test','assets')) {
    $taskGenerated=[IO.Path]::GetFullPath((Join-Path $taskDestination $taskSourceFolder))
    $taskBoundary=[IO.Path]::GetFullPath($taskStage)+[IO.Path]::DirectorySeparatorChar
    if(!$taskGenerated.StartsWith($taskBoundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid snapshot source path'}
    if(Test-Path -LiteralPath $taskGenerated){Remove-Item -LiteralPath $taskGenerated -Recurse -Force}
  }
  robocopy $taskSource $taskDestination /E /XJ /XD build .dart_tool ephemeral target .git .gradle /XF '*.log' /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -ge 8){throw "Source snapshot failed: $taskComponent"}
}
Push-Location (Join-Path $taskStage 'app')
try {
  flutter build windows --release "--dart-define=OURNET_BUILD=$taskBuild"
  if($LASTEXITCODE -ne 0){throw 'Windows build failed; close running release-build windows first'}
  New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
  Copy-Item -Path 'build/windows/x64/runner/Release/*' -Destination $taskOutput -Recurse
  foreach($taskGuide in @('TRY_IT.md','PRIVATE_DRIVE.md','PERFORMANCE.md','PARITY.md')) {
    Copy-Item -LiteralPath (Join-Path $taskRoot $taskGuide) -Destination $taskOutput
  }
  @'
param([ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Profile='main')
Start-Process -FilePath (Join-Path $PSScriptRoot 'ournet.exe') -ArgumentList "--profile=$Profile" -WorkingDirectory $PSScriptRoot -WindowStyle Normal
'@ | Set-Content (Join-Path $taskOutput 'Launch.ps1')
  'Unzip the entire folder. Double-click ournet.exe, or run .\Launch.ps1 -Profile alice. Use a fresh profile for device enrolment. Your identity and database remain in your Windows user profile when you replace this application folder.' | Set-Content (Join-Path $taskOutput 'START-HERE.txt')
  Compress-Archive -Path "$taskOutput/*" -DestinationPath "$taskOutput-windows.zip"
  "dist/OurNet-0.2.0-$taskBuild" | Set-Content (Join-Path $taskRoot 'dist/latest-windows.txt')
  if($Android){
    Pop-Location
    Push-Location (Join-Path $taskRoot 'app')
    flutter build apk --debug --target-platform android-arm64 "--dart-define=OURNET_BUILD=$taskBuild"
    if($LASTEXITCODE -ne 0){throw 'Android build failed'}
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-debug.apk' -Destination "$taskOutput-android-debug.apk"
  }
  Get-ChildItem -Path "$taskOutput-*" -File | Get-FileHash -Algorithm SHA256 | ForEach-Object {
    "$($_.Hash)  $([IO.Path]::GetFileName($_.Path))" | Set-Content "$($_.Path).sha256"
    $_ | Select-Object Hash,Path
  }
} finally {Pop-Location}
