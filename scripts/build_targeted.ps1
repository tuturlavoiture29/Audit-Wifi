param(
  [string]$First    = "Arthur",
  [string]$Last     = "Charvet",
  [string]$Company  = "Entremont",
  [string]$StreetNo = "11",
  [string]$Street   = "Vannetais",
  [string]$City     = "Guengat",
  [string]$Dept     = "Finistere",
  [string]$Country  = "France",
  [int]   $YearMin  = 2015,
  [int]   $YearMax  = 2026,
  [string]$OutFile  = "C:\Audit-Wifi\lists\targeted_build.txt"
)

$tok = @($First,$Last,$Company,$Street,$City,$Dept,$Country) | Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Unique
function V { param($w) @($w, $w.ToLower(), $w.ToUpper(), ($w.Substring(0,1).ToUpper()+$w.Substring(1).ToLower())) | Select-Object -Unique }

$words = foreach($t in $tok){ V $t }

# combinaisons avec s?parateurs
$seps = @("","-","_",".")

$combos = @()
foreach($a in $words){
  foreach($b in $words){
    if($a -ne $b){
      foreach($s in $seps){
        $combos += "$a$s$b"
      }
    }
  }
}

# base + combos
$base = ($words + $combos) | Select-Object -Unique

# suffixes num?riques & ponctuation
$years = ($YearMin..$YearMax | ForEach-Object { $_.ToString() })
$plus  = @()
foreach($w in $base){
  $plus += $w
  $plus += "$w$StreetNo"
  foreach($y in $years){
    $plus += "$w$y"
    $plus += "$w$y."
    $plus += "$w$y!"
  }
  $plus += "$w!"
  $plus += "$w."
}

# variantes leets l?g?res sur quelques tokens courts
function Leet {
  param($w)
  $w = $w -replace "a","@" -replace "e","3" -replace "i","1" -replace "o","0"
  return $w
}
$lite = foreach($w in $base){ if($w.Length -le 14){ Leet ($w.ToLower()) } }

# fusion + nettoyage
$list = ($base + $plus + $lite) | Where-Object { $_ -and $_.Length -ge 4 } | Sort-Object -Unique
$list | Set-Content -Path $OutFile -Encoding ascii
Write-Host ("[OK] Wordlist cibl?e : {0} (count: {1})" -f $OutFile, $list.Count)
