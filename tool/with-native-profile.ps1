# Hooks strip custom environment variables. A declared file dependency makes
# profile selection visible to the hook and invalidates its cached output.
param(
  [string]$Root = (Split-Path $PSScriptRoot -Parent),
  [Parameter(Mandatory)][scriptblock]$Command
)
$ErrorActionPreference = 'Stop'
$taskProfileFile = Join-Path $Root 'native/build-profile.txt'
$taskPreviousProfile = [IO.File]::ReadAllText($taskProfileFile)
try {
  [IO.File]::WriteAllText($taskProfileFile, 'release')
  & $Command
} finally {
  [IO.File]::WriteAllText($taskProfileFile, $taskPreviousProfile)
}
