param(
  [ValidateSet('Start', 'Stop')][string]$Action = 'Start',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bunPath = Join-Path $projectDirectory 'work\runtime\bun-windows-x64\bun.exe'
if (!(Test-Path -LiteralPath $bunPath)) {
  $installedBun = Get-Command bun.exe -ErrorAction SilentlyContinue
  if ($installedBun) { $bunPath = $installedBun.Source }
}
$serverEntry = Join-Path $projectDirectory 'build\server\index.js'
$dataDirectory = Join-Path $projectDirectory 'data'
$pidPath = Join-Path $PSScriptRoot 'serverPid.txt'
$serverUrl = 'http://127.0.0.1:3000'

function Get-LocalServer {
  if (!(Test-Path -LiteralPath $pidPath)) { return $null }
  $serverProcessId = 0
  if (![int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$serverProcessId)) { return $null }
  $serverProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $serverProcessId"
  if ($serverProcess -and $serverProcess.ExecutablePath -eq $bunPath -and $serverProcess.CommandLine.Contains($serverEntry)) {
    return $serverProcess
  }
  return $null
}

$runningServer = Get-LocalServer
if ($Action -eq 'Stop') {
  if ($runningServer) {
    Stop-Process -Id $runningServer.ProcessId
    Write-Host 'ToonFlow stopped. Project data has been preserved.'
  } else {
    Write-Host 'ToonFlow is already stopped.'
  }
  if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath }
  exit 0
}

if (!(Test-Path -LiteralPath $bunPath)) { throw 'Install Bun 1.3.14 or restore work/runtime/bun-windows-x64/bun.exe before starting.' }
if (!(Test-Path -LiteralPath $serverEntry)) { throw 'The server build is missing. Run bun install --frozen-lockfile, then bun run build:server before starting.' }

if (!$runningServer) {
  $listener = Get-NetTCPConnection -State Listen -LocalPort 3000 -ErrorAction SilentlyContinue
  if ($listener) { throw 'Port 3000 is occupied by another process. Stop that process before starting ToonFlow.' }
  New-Item -ItemType Directory -Path (Join-Path $dataDirectory 'workspaces\myProject') -Force | Out-Null
  $env:NODE_ENV = 'production'
  $env:TOONFLOW_DATA_DIR = $dataDirectory
  $env:PATH = (Split-Path $bunPath) + ';' + $env:PATH
  $startedServer = Start-Process -FilePath $bunPath -ArgumentList ('"' + $serverEntry + '"') -WorkingDirectory $projectDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $PSScriptRoot 'server.log') -RedirectStandardError (Join-Path $PSScriptRoot 'serverError.log') -PassThru
  Set-Content -LiteralPath $pidPath -Value $startedServer.Id -Encoding Ascii
}

$ready = $false
for ($attempt = 0; $attempt -lt 45; $attempt++) {
  try {
    $response = Invoke-RestMethod -Uri ($serverUrl + '/api/workspaces/list') -TimeoutSec 2
    if ($response.code -eq 200 -and $response.data.absolutePath -eq (Join-Path $dataDirectory 'workspaces')) {
      $ready = $true
      break
    }
  } catch {}
  if (!(Get-LocalServer)) { throw "ToonFlow exited. See $PSScriptRoot\serverError.log" }
  Start-Sleep -Seconds 1
}
if (!$ready) { throw "ToonFlow did not become ready. See $PSScriptRoot\serverError.log" }
Write-Host "ToonFlow is running at $serverUrl"
if (!$NoBrowser) { Start-Process $serverUrl }
