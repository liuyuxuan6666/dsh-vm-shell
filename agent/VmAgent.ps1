<#
  VmAgent.ps1 - a localhost agent that gives you an ELEVATED PowerShell
  inside a Hyper-V guest, plus raw host-level input injection for bootstrap.

  Why this exists
  ---------------
  A normal user process cannot drive an elevated window (UIPI) and cannot touch
  the UAC secure desktop. Inside a VM there is a way around both: inject the
  keyboard/mouse through the hypervisor (Msvm_Keyboard / Msvm_SyntheticMouse).
  The guest sees virtual hardware, so UAC is just another dialog it can answer.

  On top of that, this agent exposes PowerShell Direct (VMBus, no network,
  no WinRM listener) so day-to-day work is structured script execution rather
  than clicking pixels. Vision is a bootstrap aid, not the main path.

  Requirements
  ------------
  * Windows with Hyper-V, agent running as Administrator or SYSTEM
  * Guest running Windows 10/11 or Server 2016+ with a local admin account
  * Guest console in BASIC session (enhanced session breaks injection)

  Protocol
  --------
  127.0.0.1:<port>, one JSON object per line, one JSON reply per line.
  Every request except "ping" must carry "t": "<token>".

  Start it through Install-VmAgent.ps1; running it by hand is supported too:
    powershell -ExecutionPolicy Bypass -File VmAgent.ps1
#>
param(
  [string]$ConfigPath = (Join-Path $env:ProgramData 'DshVmShell\config.json'),
  [string]$VmName = '',
  [int]$Port = 0,
  [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
$NS = 'root\virtualization\v2'
$StateDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
$LogFile = Join-Path $StateDir 'agent.log'

function Log([string]$m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
  if ($Verbose) { Write-Host $line }
}

# ----------------------------------------------------------------- config
if (-not (Test-Path $ConfigPath)) {
  throw "config not found: $ConfigPath (run Install-VmAgent.ps1 first)"
}
$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
if ($VmName) { $cfg.vm = $VmName }
if ($Port) { $cfg.port = $Port }
if (-not $cfg.port) { $cfg.port = 17801 }
if (-not $cfg.token) { throw "config has no token" }

# ----------------------------------------------------------------- Hyper-V
function Get-VmInstance([string]$name) {
  Get-CimInstance -Namespace $NS -ClassName Msvm_ComputerSystem |
    Where-Object { $_.ElementName -eq $name } | Select-Object -First 1
}

function Get-VmList {
  @(Get-CimInstance -Namespace $NS -ClassName Msvm_ComputerSystem) |
    Where-Object { $_.ElementName -ne $env:COMPUTERNAME }
}

# One Msvm_Keyboard / Msvm_SyntheticMouse exists per VM. SystemName is the VM's
# GUID on current builds, so match on the instance rather than on the name.
function Get-InputDevice([string]$className, [string]$vm) {
  $all = @(Get-CimInstance -Namespace $NS -ClassName $className -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { return $null }
  $vmInstance = Get-VmInstance $vm
  if ($vmInstance) {
    $hit = $all | Where-Object { $_.SystemName -eq $vmInstance.Name } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $all[0]
}

# Call a WMI method, binding positional values to the real parameter names.
# Parameter names and even their order differ between Hyper-V builds.
function Invoke-MethodPositional($obj, [string]$methodName, [object[]]$values) {
  $m = $obj.CimClass.CimClassMethods | Where-Object { $_.Name -eq $methodName } | Select-Object -First 1
  if (-not $m) { throw "method '$methodName' not found on $($obj.CimClass.CimClassName)" }
  $names = @($m.Parameters | Select-Object -ExpandProperty Name)
  $argMap = @{}
  for ($i = 0; $i -lt $values.Count -and $i -lt $names.Count; $i++) { $argMap[$names[$i]] = $values[$i] }
  return Invoke-CimMethod -InputObject $obj -MethodName $methodName -Arguments $argMap
}

function Get-ScreenPng([int]$w, [int]$h, [string]$fmt) {
  $vm = Get-VmInstance $cfg.vm
  if (-not $vm) { throw "VM '$($cfg.vm)' not found" }
  $svc = Get-CimInstance -Namespace $NS -ClassName Msvm_VirtualSystemManagementService
  $m = $svc.CimClass.CimClassMethods | Where-Object { $_.Name -eq 'GetVirtualSystemThumbnailImage' } | Select-Object -First 1
  if (-not $m) { throw 'GetVirtualSystemThumbnailImage not found' }
  # Bind by name: this method's parameter order is alphabetical, not logical.
  $argMap = @{}
  foreach ($p in $m.Parameters) {
    switch ($p.CimType.ToString()) {
      'Reference' { $argMap[$p.Name] = $vm }
      'UInt16' {
        if ($p.Name -match 'Height') { $argMap[$p.Name] = [uint16]$h }
        elseif ($p.Name -match 'Width') { $argMap[$p.Name] = [uint16]$w }
      }
    }
  }
  $r = Invoke-CimMethod -InputObject $svc -MethodName 'GetVirtualSystemThumbnailImage' -Arguments $argMap
  if ($r.ReturnValue -ne 0) { throw "thumbnail failed, returnvalue=$($r.ReturnValue) (sizes above ~1024 are rejected)" }

  $data = $r.ImageData
  $pix = [int]($data.Length / ($w * $h))
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      $i = ($y * $w + $x) * $pix
      $v = ([int]$data[$i] -shl 8) -bor [int]$data[$i + 1]
      # Real byte order from Hyper-V thumbnails is BGR565; RGB565 gives purple/green noise.
      if ($fmt -eq 'rgb565') {
        $rr = [int]((($v -shr 11) -band 0x1F) * 255 / 31)
        $gg = [int]((($v -shr 5) -band 0x3F) * 255 / 63)
        $bb = [int](($v -band 0x1F) * 255 / 31)
      } else {
        $bb = [int]((($v -shr 11) -band 0x1F) * 255 / 31)
        $gg = [int]((($v -shr 5) -band 0x3F) * 255 / 63)
        $rr = [int](($v -band 0x1F) * 255 / 31)
      }
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($rr, $gg, $bb))
    }
  }
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return [Convert]::ToBase64String($ms.ToArray())
}

# ----------------------------------------------------------------- PowerShell Direct
$script:Session = $null

function Get-PsSession {
  if ($script:Session -and $script:Session.State -eq 'Opened') { return $script:Session }
  if (-not $cfg.guestUser -or -not $cfg.guestPassword) {
    throw "no guestUser/guestPassword in config; write them or run Install-VmAgent.ps1"
  }
  $sec = ConvertTo-SecureString $cfg.guestPassword -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($cfg.guestUser, $sec)
  Log "opening PowerShell Direct session to $($cfg.vm) as $($cfg.guestUser)"
  $script:Session = New-PSSession -VMName $cfg.vm -Credential $cred -ErrorAction Stop
  return $script:Session
}

function Reset-PsSession {
  if ($script:Session) { try { Remove-PSSession $script:Session -ErrorAction SilentlyContinue } catch { } }
  $script:Session = $null
}

# Run one PowerShell script inside the guest, elevated, and return its text output.
function Invoke-GuestScript([string]$base64, [int]$timeoutSec) {
  if ($timeoutSec -le 0) { $timeoutSec = 120 }
  $s = Get-PsSession
  $sb = {
    param($b64)
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    $code = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    $Error.Clear()
    try {
      $out = & ([scriptblock]::Create($code)) 2>&1 | Out-String
    } catch {
      $out = "AGENT-ERROR: $($_.Exception.Message)"
    }
    $err = ($Error | ForEach-Object { $_.ToString() }) -join "`n"
    $elevated = $false
    try {
      $id = [Security.Principal.WindowsIdentity]::GetCurrent()
      $p = New-Object Security.Principal.WindowsPrincipal($id)
      $elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    return [pscustomobject]@{
      Output   = $out
      Errors   = $err
      HostName = $env:COMPUTERNAME
      User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
      Elevated = $elevated
      PSVersion = $PSVersionTable.PSVersion.ToString()
    }
  }
  $r = Invoke-Command -Session $s -ScriptBlock $sb -ArgumentList $base64 -ErrorAction Stop
  return $r
}

# ----------------------------------------------------------------- ops
function Invoke-Op($req) {
  $op = [string]$req.op
  switch ($op) {
    'ping' { return @{ ok = $true; pong = $true; name = 'dsh-vm-shell'; version = '1.0.0' } }

    'info' {
      $vm = Get-VmInstance $cfg.vm
      $s = $null
      try { $s = Get-PsSession } catch { }
      return @{
        ok      = $true
        vm      = $cfg.vm
        state   = if ($vm) { $vm.EnabledState } else { $null }
        guest   = $cfg.guestUser
        session = if ($s) { $s.State.ToString() } else { 'none' }
      }
    }

    'ps' {
      if (-not $req.script) { throw "ps needs 'script'" }
      $b64 = [string]$req.script
      $timeout = if ($req.timeout) { [int]$req.timeout } else { 120 }
      try {
        $r = Invoke-GuestScript $b64 $timeout
      } catch {
        Reset-PsSession
        throw
      }
      return @{
        ok       = $true
        output   = $r.Output
        errors   = $r.Errors
        host     = $r.HostName
        user     = $r.User
        elevated = $r.Elevated
        ps       = $r.PSVersion
      }
    }

    'ps-reset' { Reset-PsSession; return @{ ok = $true } }

    'key' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      if (-not $kbd) { throw 'no Msvm_Keyboard instance (is the VM running?)' }
      $a = Invoke-MethodPositional $kbd 'PressKey' @([uint32]$req.vk)
      $b = Invoke-MethodPositional $kbd 'ReleaseKey' @([uint32]$req.vk)
      return @{ ok = (($a.ReturnValue -eq 0) -and ($b.ReturnValue -eq 0)); rc = @($a.ReturnValue, $b.ReturnValue) }
    }

    'keydown' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      $r = Invoke-MethodPositional $kbd 'PressKey' @([uint32]$req.vk)
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue }
    }

    'keyup' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      $r = Invoke-MethodPositional $kbd 'ReleaseKey' @([uint32]$req.vk)
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue }
    }

    'text' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      $r = Invoke-MethodPositional $kbd 'TypeText' @([string]$req.text)
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue; asciiOnly = $true }
    }

    'click' {
      $mouse = Get-InputDevice 'Msvm_SyntheticMouse' $cfg.vm
      if (-not $mouse) { throw 'no Msvm_SyntheticMouse instance' }
      $btn = if ($req.button) { [uint32]$req.button } else { [uint32]2 }
      $m = Invoke-MethodPositional $mouse 'SetAbsolutePosition' @([int]$req.x, [int]$req.y)
      $c = Invoke-MethodPositional $mouse 'ClickButton' @($btn)
      return @{ ok = (($m.ReturnValue -eq 0) -and ($c.ReturnValue -eq 0)); rc = @($m.ReturnValue, $c.ReturnValue) }
    }

    'move' {
      $mouse = Get-InputDevice 'Msvm_SyntheticMouse' $cfg.vm
      $r = Invoke-MethodPositional $mouse 'SetAbsolutePosition' @([int]$req.x, [int]$req.y)
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue }
    }

    'wheel' {
      $mouse = Get-InputDevice 'Msvm_SyntheticMouse' $cfg.vm
      $r = Invoke-MethodPositional $mouse 'SetScrollPosition' @([int]$req.delta)
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue }
    }

    'ctrl-alt-del' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      $r = Invoke-MethodPositional $kbd 'TypeCtrlAltDel' @()
      return @{ ok = ($r.ReturnValue -eq 0); rc = $r.ReturnValue }
    }

    # Answer a UAC consent dialog. Alt+Y is the Yes accelerator (works on
    # localized dialogs too, where the letter stays Y).
    'uac-yes' {
      $kbd = Get-InputDevice 'Msvm_Keyboard' $cfg.vm
      [void](Invoke-MethodPositional $kbd 'PressKey' @([uint32]18))
      [void](Invoke-MethodPositional $kbd 'PressKey' @([uint32]89))
      [void](Invoke-MethodPositional $kbd 'ReleaseKey' @([uint32]89))
      [void](Invoke-MethodPositional $kbd 'ReleaseKey' @([uint32]18))
      return @{ ok = $true }
    }

    'screen' {
      $w = if ($req.w) { [int]$req.w } else { 1024 }
      $h = if ($req.h) { [int]$req.h } else { 640 }
      $f = if ($req.fmt) { [string]$req.fmt } else { 'bgr565' }
      return @{ ok = $true; png = (Get-ScreenPng $w $h $f); fmt = $f; w = $w; h = $h }
    }

    'vms' {
      return @{ ok = $true; vms = @(Get-VmList | ForEach-Object { [ordered]@{ name = $_.ElementName; state = $_.EnabledState } }) }
    }

    default { return @{ ok = $false; error = "unknown op '$op'" } }
  }
}

# ----------------------------------------------------------------- serve
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$cfg.port)
$listener.Start()
Log "agent listening on 127.0.0.1:$($cfg.port) for VM '$($cfg.vm)'"
if ($Verbose) { Write-Host "listening on 127.0.0.1:$($cfg.port)" }

while ($true) {
  try { $client = $listener.AcceptTcpClient() }
  catch { Log "accept failed: $($_.Exception.Message)"; Start-Sleep -Milliseconds 250; continue }

  try {
    $stream = $client.GetStream()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $reader = New-Object System.IO.StreamReader($stream, $utf8NoBom)
    $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
    $writer.AutoFlush = $true
    while ($true) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { break }
      $line = $line.Trim()
      if (-not $line) { continue }
      try {
        $req = $line | ConvertFrom-Json
        if (-not $req.op) { throw "missing op" }
        if ($req.op -ne 'ping' -and [string]$req.t -ne [string]$cfg.token) { throw "bad token" }
        $resp = Invoke-Op $req
      } catch {
        $resp = @{ ok = $false; error = $_.Exception.Message }
      }
      try { $writer.WriteLine(($resp | ConvertTo-Json -Compress -Depth 6)) }
      catch { break }
    }
  } catch {
    Log "connection error: $($_.Exception.Message)"
  } finally {
    try { $client.Close() } catch { }
  }
}
