# -Msix also builds a Windows MSIX package, signed with msix's test certificate
# unless -Store is given with the Partner Center Product identity values, which
# leaves it unsigned for Store upload (Microsoft signs it).
param(
  [switch]$Android,
  [switch]$Msix,
  [switch]$Store,
  [string]$IdentityName,
  [string]$Publisher,
  [string]$PublisherDisplayName
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell turns native stderr (build warnings) into terminating
# errors under 'Stop'; flutter/robocopy failures are caught via exit codes.
function flutter { $ErrorActionPreference = 'Continue'; & (Get-Command flutter -CommandType Application | Select-Object -First 1) @args }
function dart { $ErrorActionPreference = 'Continue'; & (Get-Command dart -CommandType Application | Select-Object -First 1) @args }
if($Store){
  $Msix=$true
  if(!$IdentityName -or !$Publisher -or !$PublisherDisplayName){throw '-Store needs -IdentityName, -Publisher and -PublisherDisplayName from Partner Center'}
}
# The Visual C++ runtime ournet.exe and the plugins link against, which a
# fresh Windows may not have: the newest Build Tools/Visual Studio copy.
function Get-VcRuntime {
  $taskVsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  if(!(Test-Path -LiteralPath $taskVsWhere)){throw 'vswhere not found; install Visual Studio Build Tools'}
  $taskVs=& $taskVsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  $taskCrt=Get-ChildItem -Path (Join-Path $taskVs 'VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue |
    Where-Object {$_.Parent.Parent.Name -match '^\d+(\.\d+)+$'} |
    Sort-Object {[version]$_.Parent.Parent.Name} -Descending | Select-Object -First 1
  if(!$taskCrt){throw 'Visual C++ redistributable files not found under the Visual Studio install'}
  Get-ChildItem -Path $taskCrt.FullName -Filter '*.dll'
}
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
  Get-VcRuntime | Copy-Item -Destination $taskOutput
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
  if($Msix){
    $taskMsixArgs=@(
      '--logo-path',(Join-Path $taskRoot 'store/ournet-icon-512.png'),
      '--output-path',(Join-Path $taskRoot 'dist'),
      '--output-name',"OurNet-0.2.0-$taskBuild-windows"
    )
    if($Store){$taskMsixArgs+=@('--store','--identity-name',$IdentityName,'--publisher',$Publisher,'--publisher-display-name',$PublisherDisplayName)}
    dart run msix:build @taskMsixArgs
    if($LASTEXITCODE -ne 0){throw 'MSIX build failed'}
    # Let peers reach OurNet directly without Windows asking to allow it:
    # QUIC and calls are UDP. package:msix cannot declare firewall rules.
    $taskManifest=Join-Path (Get-Location) 'build/windows/x64/runner/Release/AppxManifest.xml'
    $taskXml=[IO.File]::ReadAllText($taskManifest)
    $taskFirewall=@'
    <Extensions>
      <desktop2:Extension Category="windows.firewallRules">
        <desktop2:FirewallRules Executable="ournet.exe">
          <desktop2:Rule Direction="in" IPProtocol="UDP" Profile="all" />
        </desktop2:FirewallRules>
      </desktop2:Extension>
    </Extensions>
  </Package>
'@
    $taskXml=$taskXml -replace '</Package>\s*$',$taskFirewall
    [IO.File]::WriteAllText($taskManifest,$taskXml,(New-Object Text.UTF8Encoding $false))
    dart run msix:pack @taskMsixArgs
    if($LASTEXITCODE -ne 0){throw 'MSIX pack failed'}
  }
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
