# Releases the current version to Google Play and the Microsoft Store in one go.
#
#   tool/release-all.ps1 -Notes "What changed"            # Play internal + Store
#   tool/release-all.ps1 -Notes "..." -Track beta          # other Play track
#   tool/release-all.ps1 -SkipStore / -SkipPlay            # one store only
#   tool/release-all.ps1 -StoreNoCommit                    # Store: upload to draft, do not submit
#
# Bump the x.y.z part of `version:` in app/pubspec.yaml first (the Store needs a
# higher version every time; Play's version code is derived from the clock).
# Everything both uploads need is checked before anything is built, so a missing
# key cannot leave one store updated and the other not.
param(
  [string]$Notes,
  [ValidateSet('internal','alpha','beta','production')][string]$Track = 'internal',
  [switch]$SkipPlay,
  [switch]$SkipStore,
  [switch]$StoreNoCommit
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskSigning = Join-Path $env:USERPROFILE '.ournet-signing'
$taskProblems = @()

if(!$SkipPlay){
  if(!(Test-Path (Join-Path $taskRoot 'app/android/key.properties'))){$taskProblems += 'app/android/key.properties is missing (Play upload keystore)'}
  if(!(Test-Path (Join-Path $taskSigning 'play-service-account.json'))){$taskProblems += "$taskSigning\play-service-account.json is missing"}
}
if(!$SkipStore){
  if(!(Get-Command msstore -ErrorAction SilentlyContinue) -and !(Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/MSStore.exe'))){$taskProblems += 'msstore CLI not installed: winget install "Microsoft Store Developer CLI"'}
  $taskHasEnv = $env:MSSTORE_TENANT_ID -and $env:MSSTORE_SELLER_ID -and $env:MSSTORE_CLIENT_ID -and $env:MSSTORE_CLIENT_SECRET
  if(!$taskHasEnv -and !(Test-Path (Join-Path $taskSigning 'msstore.json'))){$taskProblems += "$taskSigning\msstore.json is missing (see tool/publish-store.ps1 header)"}
  $taskVersion = [version](((Select-String -Path (Join-Path $taskRoot 'app/pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)').Matches[0].Groups[1].Value))
  $taskLastFile = Join-Path $taskRoot 'store/submitted-version.txt'
  if((Test-Path $taskLastFile) -and $taskVersion -le [version]((Get-Content $taskLastFile -Raw).Trim())){$taskProblems += "pubspec version $taskVersion is not higher than the last Store submission; bump it"}
}
if($taskProblems){throw ("Not releasing:`n - " + ($taskProblems -join "`n - "))}

# Sequential: both builds run flutter in app/, which cannot share a build dir.
if(!$SkipPlay){
  & (Join-Path $PSScriptRoot 'release-android.ps1') -Notes $Notes -Track $Track
}
if(!$SkipStore){
  & (Join-Path $PSScriptRoot 'publish-store.ps1') -Build -NoCommit:$StoreNoCommit
}
"Done: " + (@(if(!$SkipPlay){"Play ($Track)"}; if(!$SkipStore){'Microsoft Store'}) -join ' + ')
