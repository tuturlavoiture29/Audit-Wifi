# C:\Audit-Wifi\scripts\run_s2.ps1
$ErrorActionPreference = "Stop"

$hc   = "C:\Tools\hashcat\hashcat.exe"
$hcDir = Split-Path $hc
$root = "C:\Audit-Wifi"
$pot  = Join-Path $root "potfile.txt"

# Wordlist: targeted_build si dispo, sinon context
$listA = Join-Path $root "lists\targeted_build.txt"
$listB = Join-Path $root "lists\context.txt"
$wordlist = if (Test-Path $listA) { $listA } else { $listB }

$hashes = Get-ChildItem (Join-Path $root "hashes") -Filter *.22000 | Where-Object Length -gt 0
$masks  = @('?d?d','?d?d?d?d','?d?d?d?d!')  # 2 chiffres, 4 chiffres, 4 chiffres + !

Push-Location $hcDir
foreach ($h in $hashes) {
  foreach ($m in $masks) {
    & .\hashcat.exe -m 22000 -a 6 $h.FullName $wordlist $m `
      --session "$($h.BaseName)-s2-$($m.Replace('?','q'))" `
      --potfile-path $pot --status --status-timer 15 --logfile-disable
  }
}
# Afficher les trouvailles
foreach ($h in $hashes) {
  & .\hashcat.exe --show -m 22000 $h.FullName --potfile-path $pot
}
Pop-Location
