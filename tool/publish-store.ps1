# Uploads a Store-built MSIX to the Microsoft Store and submits it for
# certification, using the Microsoft Store Developer CLI (msstore).
#
#   tool/publish-store.ps1 -Build          # build the .msix, then publish it
#   tool/publish-store.ps1                 # publish the newest dist/*-windows.msix
#   tool/publish-store.ps1 -NoCommit       # upload to the draft only, do not submit
#
# One-time setup (needs the user):
#   winget install "Microsoft Store Developer CLI"
#   Partner Center: associate a Microsoft Entra ID tenant, add an Entra app with
#   the Manager role, create a client secret. Then save the four values in
#   %USERPROFILE%\.ournet-signing\msstore.json (never in the repo):
#   { "tenantId": "...", "sellerId": "...", "clientId": "...", "clientSecret": "..." }
# MSSTORE_TENANT_ID, MSSTORE_SELLER_ID, MSSTORE_CLIENT_ID and MSSTORE_CLIENT_SECRET
# override the file (for CI).
#
# The first submission of a product must be completed by hand in Partner Center
# (listing, age rating); the API and CLI only update after that.
# The Store needs a higher package version for every submission: bump the
# x.y.z part of `version:` in app/pubspec.yaml (the +N build number is ignored
# by the MSIX). store/submitted-version.txt records the last version sent.
param(
  [switch]$Build,
  [string]$Msix,
  [switch]$NoCommit
)
$ErrorActionPreference = 'Stop'
# msstore prints its banner to stderr, which 'Stop' turns into a terminating
# error; native tools report failure through their exit code instead.
function Invoke-Native([scriptblock]$Command) {
  $ErrorActionPreference = 'Continue'
  & $Command
}
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskProductId = '9N6P4X13QG9M'
$taskIdentityName = 'Chozabu.OurNet'
$taskPublisher = 'CN=30BA6359-7C85-4DB7-96B1-937D4F790B29'
$taskPublisherDisplayName = 'Chozabu'

# Installed from the Store, msstore may not be on PATH in an older shell.
$taskCli = (Get-Command msstore -ErrorAction SilentlyContinue).Source
if(!$taskCli){$taskCli = (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/MSStore.exe') -ErrorAction SilentlyContinue).FullName}
if(!$taskCli){throw 'msstore not found: winget install "Microsoft Store Developer CLI"'}

# Version guard: the Store rejects a package whose version is not higher.
$taskVersion = [version](((Select-String -Path (Join-Path $taskRoot 'app/pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)').Matches[0].Groups[1].Value))
$taskLastFile = Join-Path $taskRoot 'store/submitted-version.txt'
if(Test-Path $taskLastFile){
  $taskLast = [version]((Get-Content $taskLastFile -Raw).Trim())
  if($taskVersion -le $taskLast){throw "pubspec version $taskVersion is not higher than the last submitted $taskLast; bump it first"}
}

if($Build){
  & (Join-Path $PSScriptRoot 'package.ps1') -Store -IdentityName $taskIdentityName -Publisher $taskPublisher -PublisherDisplayName $taskPublisherDisplayName
  if($LASTEXITCODE -ne 0){throw 'package.ps1 failed'}
}
if(!$Msix){
  $taskNewest = Get-ChildItem (Join-Path $taskRoot 'dist') -Filter '*-windows.msix' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(!$taskNewest){throw 'No dist/*-windows.msix; run with -Build'}
  $Msix = $taskNewest.FullName
}
# A test-signed build (no -Store) has the wrong identity and would be rejected.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$taskZip = [IO.Compression.ZipFile]::OpenRead($Msix)
try{
  $taskEntry = $taskZip.GetEntry('AppxManifest.xml')
  $taskReader = New-Object IO.StreamReader($taskEntry.Open())
  $taskManifest = $taskReader.ReadToEnd(); $taskReader.Dispose()
} finally {$taskZip.Dispose()}
if($taskManifest -notmatch [regex]::Escape("Name=`"$taskIdentityName`"")){throw "$Msix does not carry the Store identity $taskIdentityName; rebuild with -Build"}

# Credentials: environment first, then the signing folder.
$taskCred = @{}
$taskCredFile = Join-Path $env:USERPROFILE '.ournet-signing/msstore.json'
if(Test-Path $taskCredFile){(Get-Content $taskCredFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {$taskCred[$_.Name] = $_.Value}}
$taskTenant = if($env:MSSTORE_TENANT_ID){$env:MSSTORE_TENANT_ID}else{$taskCred.tenantId}
$taskSeller = if($env:MSSTORE_SELLER_ID){$env:MSSTORE_SELLER_ID}else{$taskCred.sellerId}
$taskClient = if($env:MSSTORE_CLIENT_ID){$env:MSSTORE_CLIENT_ID}else{$taskCred.clientId}
$taskSecret = if($env:MSSTORE_CLIENT_SECRET){$env:MSSTORE_CLIENT_SECRET}else{$taskCred.clientSecret}
if(!$taskTenant -or !$taskSeller -or !$taskClient -or !$taskSecret){throw "Store credentials missing: fill in $taskCredFile or the MSSTORE_* environment variables"}
Invoke-Native { & $taskCli reconfigure --tenantId $taskTenant --sellerId $taskSeller --clientId $taskClient --clientSecret $taskSecret 2>&1 | Out-Null }
if($LASTEXITCODE -ne 0){throw 'msstore reconfigure failed'}

# The positional argument is the project folder. msstore picks the package
# from --inputDirectory, so give it a folder holding only the .msix checked
# above; dist/ holds older builds too.
$taskUpload = Join-Path $taskRoot 'build/store-upload'
if(Test-Path -LiteralPath $taskUpload){Remove-Item -LiteralPath $taskUpload -Recurse -Force}
New-Item -ItemType Directory -Path $taskUpload | Out-Null
Copy-Item -LiteralPath $Msix -Destination $taskUpload
$taskArgs = @('publish', (Join-Path $taskRoot 'app'), '--inputDirectory', $taskUpload, '--appId', $taskProductId, '--uploadTimeout', '900')
if($NoCommit){$taskArgs += '--noCommit'}
Invoke-Native { & $taskCli @taskArgs }
if($LASTEXITCODE -ne 0){throw 'msstore publish failed'}
if(!$NoCommit){$taskVersion.ToString() | Set-Content $taskLastFile}
"Published $Msix version $taskVersion to $taskProductId"
