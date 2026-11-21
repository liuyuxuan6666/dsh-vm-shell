<#
  Install-VmAgent.ps1 - install DshVmShell's agent as a SYSTEM scheduled task.

  Run this once, in an elevated PowerShell:

    powershell -ExecutionPolicy Bypass -File Install-VmAgent.ps1 `
        -VmName win11 -GuestUser dsh -GuestPassword 'YourGuestPassword'

  What it does
  ------------
  * validates the VM and the guest credential arguments
  * writes %ProgramData%\DshVmShell\config.json (password, Administrators + SYSTEM only)
  * writes %ProgramData%\DshVmShell\token.txt  (loopback API token, readable by you)
  * registers the "DshVmShell" scheduled task (SYSTEM, at startup) and starts it

  The agent then stays up across reboots. No console window, no UAC.
#>
param(
  [Parameter(Mandatory = $true)][string]$VmName,
  [Parameter(Mandatory = $true)][string]$GuestUser,
  [Parameter(Mandatory = $true)][string]$GuestPassword,
  [int]$Port = 17801,
  [string]$TaskName = 'DshVmShell'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$agent = Join-Path $here 'VmAgent.ps1'
if (-not (Test-Path $agent)) { throw "VmAgent.ps1 not found next to this script" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'run this in an elevated PowerShell (Administrator)'
}

# --- validate the VM -------------------------------------------------------
$vm = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem |
      Where-Object { $_.ElementName -eq $VmName } | Select-Object -First 1
if (-not $vm) {
  $names = (Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem |
            Where-Object { $_.ElementName -ne $env:COMPUTERNAME } | ForEach-Object { $_.ElementName }) -join ', '
  throw "VM '$VmName' not found. Available: $names"
}

# --- write config ----------------------------------------------------------
$dir = Join-Path $env:ProgramData 'DshVmShell'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$token = -join ((48..57) + (97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ })
$cfg = [ordered]@{
  vm            = $VmName
  guestUser     = $GuestUser
  guestPassword = $GuestPassword
  port          = $Port
  token         = $token
}
$cfgPath = Join-Path $dir 'config.json'
($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8 -NoNewline

# Lock the credential down: SYSTEM + Administrators only.
& icacls.exe $cfgPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null

# The token is what a normal user process needs, so it stays readable.
$tokenPath = Join-Path $dir 'token.txt'
Set-Content -Path $tokenPath -Value $token -Encoding ASCII -NoNewline
& icacls.exe $tokenPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' 'Users:(R)' | Out-Null

# --- register the task -----------------------------------------------------
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$runAs = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.ExecutionTimeLimit = 'PT0S'

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $runAs -Settings $settings | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host ''
Write-Host "VM             : $VmName"
Write-Host "Guest account  : $GuestUser"
Write-Host "Agent          : $agent"
Write-Host "Config         : $cfgPath  (password, admin-only)"
Write-Host "Token          : $tokenPath"
Write-Host "Task '$TaskName': $state"
Write-Host "Listening      : 127.0.0.1:$Port"
Write-Host ''
Write-Host 'Next: install the DSH plugin, or try a request by hand:'
Write-Host "  `$t = Get-Content '$tokenPath' -Raw"
Write-Host "  See README.md for the request format."
