<#
  Test-Agent.ps1 - send one HMAC-signed request to the agent by hand.

    powershell -ExecutionPolicy Bypass -File Test-Agent.ps1 -Body '{"op":"info"}'

  Options:
    -SecretPath  default: %ProgramData%\DshVmShell\secret.txt
    -Port        default: 17801
#>
param(
  [string]$Body = '{"op":"info"}',
  [string]$SecretPath = (Join-Path $env:ProgramData 'DshVmShell\secret.txt'),
  [int]$Port = 17801
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SecretPath)) { throw "no secret at $SecretPath" }
$hex = (Get-Content -Path $SecretPath -Raw).Trim()
$key = New-Object byte[] ($hex.Length / 2)
for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }

$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$nonce = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))

$h = New-Object System.Security.Cryptography.HMACSHA256
$h.Key = $key
$sig = [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ts.$nonce.$b"))).Replace('-', '').ToLowerInvariant()
$h.Dispose()

$envelope = @{ v = 1; ts = $ts; nonce = $nonce; b = $b; sig = $sig } | ConvertTo-Json -Compress

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', $Port)
try {
  $stream = $client.GetStream()
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $writer = New-Object System.IO.StreamWriter($stream, $utf8)
  $writer.AutoFlush = $true
  $reader = New-Object System.IO.StreamReader($stream, $utf8)
  $writer.WriteLine($envelope)
  $reader.ReadLine()
} finally {
  $client.Close()
}
