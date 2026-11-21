<#
  Uninstall-VmAgent.ps1 - stop and remove the DshVmShell agent.

    powershell -ExecutionPolicy Bypass -File Uninstall-VmAgent.ps1

  Removes the scheduled task and the saved credential. Leaves the guest
  untouched (the local account it uses is yours to keep or delete).
#>
param(
  [string]$TaskName = 'DshVmShell',
  [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "removed scheduled task '$TaskName'"
} else {
  Write-Host "scheduled task '$TaskName' not found"
}

# The agent may also be running by hand from a console.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'VmAgent\.ps1' } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped pid $($_.ProcessId)" } catch { }
  }

if (-not $KeepConfig) {
  $dir = Join-Path $env:ProgramData 'DshVmShell'
  if (Test-Path $dir) {
    Remove-Item -Path $dir -Recurse -Force
    Write-Host "removed $dir"
  }
}

Write-Host 'done'
