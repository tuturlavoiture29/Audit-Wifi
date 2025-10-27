# env_check.ps1 — vérifie l'environnement et écrit un log JSONL
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$logFile = Join-Path $logs ("env-{0}.jsonl" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Have($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

$hashcatPath = 'C:\Tools\hashcat\hashcat.exe'
$hashcatVer  = if (Test-Path $hashcatPath) { & $hashcatPath --version } else { 'n/a' }
$pythonVer   = if (Have 'python') { (python --version) } else { 'n/a' }

$report = [ordered]@{
  ts      = (Get-Date).ToUniversalTime().ToString('o')
  stage   = 'env-check'
  hashcat = $hashcatVer
  python  = $pythonVer
  result  = 'ok'
}

$report | ConvertTo-Json -Compress | Out-File -FilePath $logFile -Append -Encoding utf8
Write-Host "[OK] Rapport env: $logFile"
