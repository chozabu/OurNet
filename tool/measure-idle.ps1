param([Parameter(Mandatory=$true)][int]$ProcessId,[ValidateRange(5,60)][int]$Seconds=30)
$ErrorActionPreference='Stop'
$taskProcess=Get-Process -Id $ProcessId
$taskStartCpu=$taskProcess.TotalProcessorTime.TotalSeconds
$taskWatch=[Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds $Seconds
$taskProcess.Refresh()
$taskElapsed=$taskWatch.Elapsed.TotalSeconds
[pscustomobject]@{
  ProcessId=$ProcessId
  Seconds=[math]::Round($taskElapsed,2)
  CpuPercentOfOneCore=[math]::Round(100*($taskProcess.TotalProcessorTime.TotalSeconds-$taskStartCpu)/$taskElapsed,3)
  WorkingSetMiB=[math]::Round($taskProcess.WorkingSet64/1MB,2)
  PrivateMiB=[math]::Round($taskProcess.PrivateMemorySize64/1MB,2)
} | ConvertTo-Json
