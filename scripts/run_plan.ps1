param(
  [Parameter(Mandatory=$true)] [ValidateSet("cpu","gpu")] [string]$profile,
  [Parameter(Mandatory=$true)] [ValidateSet("psk","enterprise")] [string]$mode,
  [Parameter(Mandatory=$true)] [string]$hash,
  [string]$ssid,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# chemins
$root    = Split-Path -Parent $PSScriptRoot
$logs    = Join-Path $root "logs"
$reports = Join-Path $root "reports"
New-Item -ItemType Directory -Force -Path $logs, $reports | Out-Null
$logFile = Join-Path $logs ("run-{0}.jsonl" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

# validations
if ($mode -eq "psk" -and [string]::IsNullOrWhiteSpace($ssid)) { throw "--ssid is required in psk mode" }
if (-not (Test-Path $hash)) { throw "Hash file not found: $hash" }

# hashcat
$hashcatPath = "C:\Tools\hashcat\hashcat.exe"
$hashcatVer  = "n/a"
if (Test-Path $hashcatPath) { $hashcatVer = & $hashcatPath --version }

# log JSON
$drySuffix = if ($DryRun) { " -DryRun" } else { "" }
$rec = [ordered]@{
  ts       = (Get-Date).ToUniversalTime().ToString("o")
  stage    = "sprint0-validate"
  profile  = $profile
  mode     = $mode
  cmd      = "run_plan.ps1 -profile $profile -mode $mode -hash $hash -ssid $ssid$drySuffix"
  ssid     = $ssid
  versions = "hashcat:$hashcatVer"
  result   = "validated"
}
$rec | ConvertTo-Json -Compress | Out-File -FilePath $logFile -Append -Encoding utf8
Write-Host "[OK] Args validated. Log: $logFile"

# dry-run : afficher les commandes
if ($DryRun) {
  $pot = Join-Path $root "potfile.txt"
  $hc  = $hashcatPath

  Write-Host ""
  Write-Host "=== Hashcat commands (PSK) ==="
  Write-Host ""

  $s1  = "`"$hc`" -m 22000 -a 0 `"$hash`" `"$root\lists\context.txt`" -r `"$root\rules\rules-fr-lite.rule`" --session s1 --potfile-path `"$pot`" --status --status-timer 15 --logfile-disable"
  Write-Host "S1 (context + rules):"
  Write-Host $s1
  Write-Host ""

  $s2a = "`"$hc`" -m 22000 -a 6 `"$hash`" `"$root\lists\context.txt`" ?d?d --session s2a --potfile-path `"$pot`" --status --status-timer 15 --logfile-disable"
  $s2b = "`"$hc`" -m 22000 -a 6 `"$hash`" `"$root\lists\context.txt`" ?d?d?d?d --session s2b --potfile-path `"$pot`" --status --status-timer 15 --logfile-disable"
  # -> ici on met le masque contenant le '!' entre quotes simples pour éviter les problèmes d'interprétation
  $s2c = "`"$hc`" -m 22000 -a 6 `"$hash`" `"$root\lists\context.txt`" '?d?d?d?d!' --session s2c --potfile-path `"$pot`" --status --status-timer 15 --logfile-disable"
  Write-Host "S2a (word + 2 digits):"
  Write-Host $s2a
  Write-Host ""
  Write-Host "S2b (word + 4 digits):"
  Write-Host $s2b
  Write-Host ""
  Write-Host "S2c (word + 4 digits + !):"
  Write-Host $s2c
  Write-Host ""

  # idem : utiliser quotes simples autour du masque pour S3
  $s3  = "`"$hc`" -m 22000 -a 3 `"$hash`" --increment --increment-min=8 --increment-max=10 '?d?d?d?d?d?d?d?d?d?d' --session s3 --potfile-path `"$pot`" --status --status-timer 15 --logfile-disable"
  Write-Host "S3 (digits length 8-10):"
  Write-Host $s3
  Write-Host ""

  Write-Host "Tip: run S1, then S2a -> S2b -> S2c, then S3. Keep the same potfile to avoid re-testing."
  exit 0
}

Write-Host "Non-dry run not implemented here. Use the printed commands in dry-run."
