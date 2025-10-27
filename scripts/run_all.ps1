[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root    = 'C:\Audit-Wifi'
$hashDir = Join-Path $root 'hashes'
$listA   = Join-Path $root 'lists\targeted_build.txt'
$listB   = Join-Path $root 'lists\context.txt'
$rules   = Join-Path $root 'rules\rules-fr-lite.rule'
$pot     = Join-Path $root 'potfile.txt'
$logsDir = Join-Path $root 'logs'
$repDir  = Join-Path $root 'reports'
$hashcat = 'C:\Tools\hashcat\hashcat.exe'

New-Item -ItemType Directory -Force -Path $logsDir,$repDir | Out-Null

if (!(Test-Path $hashcat)) { throw "hashcat introuvable: $hashcat" }

# Choix wordlist (sans ternaire)
if (Test-Path $listA) { $wordlist = $listA } else { $wordlist = $listB }
if (!(Test-Path $wordlist)) { throw "Aucune wordlist trouvée ($listA / $listB)" }

$csv = Join-Path $repDir ("summary-{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
'file,recovered,show_lines,wordlist' | Out-File -FilePath $csv -Encoding utf8

$hashes = Get-ChildItem $hashDir -Filter *.22000 | Where-Object Length -gt 0
if (-not $hashes) { Write-Host "Aucun .22000 non-vide dans $hashDir" -ForegroundColor Yellow; exit 1 }

Write-Host ("Wordlist: {0} ({1} lignes)" -f $wordlist, (Get-Content $wordlist).Count)

foreach ($h in $hashes) {
  $name = [IO.Path]::GetFileNameWithoutExtension($h.Name)
  Write-Host "`n=== Run: $name ==="

  & $hashcat -m 22000 -a 0 $h.FullName $wordlist `
    --session $name --potfile-path $pot --status --status-timer 15 --logfile-disable

  $show = & $hashcat --show -m 22000 $h.FullName --potfile-path $pot

  # Sans ternaire
  if ([string]::IsNullOrWhiteSpace($show)) { $recovered = 0 } else { $recovered = 1 }

  ($h.Name + ',' + $recovered + ',' + ($show -split "`n").Count + ',' + $wordlist) |
    Out-File -FilePath $csv -Append -Encoding utf8

  $rec = [ordered]@{
    ts         = (Get-Date).ToUniversalTime().ToString('o')
    file       = $h.Name
    recovered  = $recovered
    show_lines = ($show -split "`n").Count
  }
  $rec | ConvertTo-Json -Compress |
    Out-File -FilePath (Join-Path $logsDir "run-$(Get-Date -Format 'yyyyMMdd').jsonl") -Append -Encoding utf8
}

Write-Host "`n[OK] Terminé. Résumé: $csv"
