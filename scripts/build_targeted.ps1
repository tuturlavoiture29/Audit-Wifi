Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [string]$InputPath = $(Join-Path (Split-Path -Parent $PSScriptRoot) 'inputs\target_seeds.json'),
    [string]$OutputPath = $(Join-Path (Split-Path -Parent $PSScriptRoot) 'lists\targeted_build.txt')
)

function Remove-Diacritics {
    param([string]$Input)
    if ([string]::IsNullOrEmpty($Input)) {
        return $Input
    }
    $normalized = $Input.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $null = $builder.Append($char)
        }
    }
    return $builder.ToString()
}

function Normalize-Key {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    return (Remove-Diacritics($Name)).ToLowerInvariant()
}

function To-TitleCase {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.Length -eq 1) { return $Text.ToUpperInvariant() }
    return $Text.Substring(0,1).ToUpperInvariant() + $Text.Substring(1).ToLowerInvariant()
}

function Collect-WordTokens {
    param($Value)
    $tokens = @()
    if ($null -eq $Value) { return $tokens }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $tokens += Collect-WordTokens -Value $item
        }
        return $tokens
    }
    $text = [string]$Value
    $text = $text.Trim()
    if (-not [string]::IsNullOrEmpty($text)) {
        $matches = [regex]::Matches($text, '[\p{L}\p{Nd}]+')
        foreach ($match in $matches) {
            $token = $match.Value
            if (-not [string]::IsNullOrEmpty($token)) {
                $tokens += $token
                $plain = Remove-Diacritics $token
                if ($plain -and $plain -ne $token) {
                    $tokens += $plain
                }
            }
        }
    }
    return $tokens
}

function Collect-YearTokens {
    param(
        $Value,
        [System.Collections.Generic.HashSet[string]]$Years,
        [System.Collections.Generic.HashSet[string]]$ShortYears,
        [System.Collections.Generic.HashSet[string]]$Dates
    )
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            Collect-YearTokens -Value $item -Years $Years -ShortYears $ShortYears -Dates $Dates
        }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($prop in $Value.PSObject.Properties) {
            Collect-YearTokens -Value $prop.Value -Years $Years -ShortYears $ShortYears -Dates $Dates
        }
        return
    }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return }
    $matches = [regex]::Matches($text, '\d{2,8}')
    foreach ($match in $matches) {
        $digits = $match.Value
        switch ($digits.Length) {
            2 { $ShortYears.Add($digits) | Out-Null }
            4 {
                $Years.Add($digits) | Out-Null
                $ShortYears.Add($digits.Substring(2,2)) | Out-Null
            }
            8 {
                $Dates.Add($digits) | Out-Null
                $yearPart = $digits.Substring(4,4)
                if ($yearPart.Length -eq 4) {
                    $Years.Add($yearPart) | Out-Null
                    $ShortYears.Add($yearPart.Substring(2,2)) | Out-Null
                }
            }
        }
    }
}

function Apply-Leet {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $map = @{
        'a' = '@'
        'e' = '3'
        'i' = '1'
        'o' = '0'
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        $lower = [char]::ToLowerInvariant($char)
        if ($map.ContainsKey($lower)) {
            $replacement = $map[$lower]
            $null = $builder.Append($replacement)
        } else {
            $null = $builder.Append($char)
        }
    }
    return $builder.ToString()
}

function Add-CaseVariants {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Token
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    $trimmed = $Token.Trim()
    if ($trimmed.Length -eq 0) { return }
    $variants = @($trimmed,
        $trimmed.ToLowerInvariant(),
        $trimmed.ToUpperInvariant(),
        (To-TitleCase $trimmed)
    ) | Select-Object -Unique
    foreach ($variant in $variants) {
        if (-not [string]::IsNullOrEmpty($variant)) {
            $Set.Add($variant) | Out-Null
        }
    }
}

function Add-Candidate {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Candidate
    )
    if ([string]::IsNullOrEmpty($Candidate)) { return }
    $value = $Candidate.Trim()
    if ([string]::IsNullOrEmpty($value)) { return }
    if ($value.Length -lt 8 -or $value.Length -gt 63) { return }
    if ($value -match '\s') { return }
    $Set.Add($value) | Out-Null
}

$root = Split-Path -Parent $PSScriptRoot
$listsDir = Join-Path $root 'lists'
$inputsDir = Join-Path $root 'inputs'
$logsDir = Join-Path $root 'logs'

New-Item -ItemType Directory -Force -Path $listsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$inputFile = if ($InputPath) { $InputPath } else { Join-Path $inputsDir 'target_seeds.json' }
$outputFile = if ($OutputPath) { $OutputPath } else { Join-Path $listsDir 'targeted_build.txt' }

$defaultSeed = [pscustomobject]@{
    prenom     = 'Arthur'
    nom        = 'Charvet'
    ville      = 'Guengat'
    rue        = 'Vannetais'
    num        = '11'
    entreprise = 'Entremont'
    annees     = 2015..2026
}

$seedData = $null
$usedDefault = $false
if (Test-Path $inputFile) {
    $raw = Get-Content -Path $inputFile -Raw -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $seedData = ConvertFrom-Json -InputObject $raw
    }
}
if (-not $seedData) {
    $seedData = @($defaultSeed)
    $usedDefault = $true
}
if ($seedData -isnot [System.Array]) {
    $seedData = @($seedData)
}

$rawTokens = New-Object System.Collections.Generic.HashSet[string]
$years = New-Object System.Collections.Generic.HashSet[string]
$shortYears = New-Object System.Collections.Generic.HashSet[string]
$dates = New-Object System.Collections.Generic.HashSet[string]

foreach ($seed in $seedData) {
    if ($null -eq $seed) { continue }
    if ($seed -isnot [pscustomobject] -and $seed -isnot [hashtable]) { continue }
    foreach ($prop in $seed.PSObject.Properties) {
        $key = Normalize-Key $prop.Name
        switch ($key) {
            'annee' { Collect-YearTokens -Value $prop.Value -Years $years -ShortYears $shortYears -Dates $dates }
            'annees' { Collect-YearTokens -Value $prop.Value -Years $years -ShortYears $shortYears -Dates $dates }
            'year' { Collect-YearTokens -Value $prop.Value -Years $years -ShortYears $shortYears -Dates $dates }
            'years' { Collect-YearTokens -Value $prop.Value -Years $years -ShortYears $shortYears -Dates $dates }
            default {
                $tokens = Collect-WordTokens -Value $prop.Value
                foreach ($token in $tokens) {
                    if (-not [string]::IsNullOrWhiteSpace($token)) {
                        $rawTokens.Add($token.Trim()) | Out-Null
                    }
                }
            }
        }
    }
}

if ($rawTokens.Count -eq 0) {
    foreach ($token in @('Audit','Wifi','Target')) {
        $rawTokens.Add($token) | Out-Null
    }
}

$baseCandidates = New-Object System.Collections.Generic.HashSet[string]
foreach ($token in $rawTokens) {
    Add-CaseVariants -Set $baseCandidates -Token $token
}

$tokenList = @($rawTokens)

$joiners = @('', '.', '-', '_')
for ($i = 0; $i -lt $tokenList.Count; $i++) {
    $a = $tokenList[$i]
    $aLower = $a.ToLowerInvariant()
    $aTitle = To-TitleCase $aLower
    for ($j = 0; $j -lt $tokenList.Count; $j++) {
        if ($i -eq $j) { continue }
        $b = $tokenList[$j]
        $bLower = $b.ToLowerInvariant()
        $bTitle = To-TitleCase $bLower
        foreach ($sep in $joiners) {
            if ($sep -eq '') {
                Add-CaseVariants -Set $baseCandidates -Token ($aLower + $bLower)
                Add-CaseVariants -Set $baseCandidates -Token ($aTitle + $bTitle)
            } else {
                Add-CaseVariants -Set $baseCandidates -Token ($aLower + $sep + $bLower)
                Add-CaseVariants -Set $baseCandidates -Token ($aTitle + $sep + $bTitle)
            }
        }
        for ($k = 0; $k -lt $tokenList.Count; $k++) {
            if ($k -eq $i -or $k -eq $j) { continue }
            $c = $tokenList[$k]
            $cLower = $c.ToLowerInvariant()
            $cTitle = To-TitleCase $cLower
            foreach ($sep in @('', '-', '_', '.')) {
                if ($sep -eq '') {
                    Add-CaseVariants -Set $baseCandidates -Token ($aLower + $bLower + $cLower)
                    Add-CaseVariants -Set $baseCandidates -Token ($aTitle + $bTitle + $cTitle)
                } else {
                    Add-CaseVariants -Set $baseCandidates -Token ($aLower + $sep + $bLower + $sep + $cLower)
                    Add-CaseVariants -Set $baseCandidates -Token ($aTitle + $sep + $bTitle + $sep + $cTitle)
                }
            }
        }
    }
}

$suffixes = New-Object System.Collections.Generic.HashSet[string]
foreach ($year in $years) {
    $suffixes.Add($year) | Out-Null
    $suffixes.Add("$year!") | Out-Null
}
foreach ($short in $shortYears) {
    if ($short.Length -eq 2) {
        $suffixes.Add($short) | Out-Null
    }
}
foreach ($date in $dates) {
    if ($date.Length -eq 8) {
        $suffixes.Add($date) | Out-Null
    }
}
foreach ($extra in @('123','11','29','29!')) {
    $suffixes.Add($extra) | Out-Null
}

$finalSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($candidate in $baseCandidates) {
    Add-Candidate -Set $finalSet -Candidate $candidate
    foreach ($suffix in $suffixes) {
        Add-Candidate -Set $finalSet -Candidate ($candidate + $suffix)
    }
    $leet = Apply-Leet $candidate.ToLowerInvariant()
    if ($leet -and $leet -ne $candidate) {
        Add-Candidate -Set $finalSet -Candidate $leet
        foreach ($suffix in $suffixes) {
            Add-Candidate -Set $finalSet -Candidate ($leet + $suffix)
        }
    }
}

$finalList = $finalSet | Sort-Object { $_.Length }, { $_ }
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($outputFile, $finalList, $encoding)

$sample = $finalList | Select-Object -First ([Math]::Min(10, $finalList.Count))
Write-Host ("[OK] Wordlist ciblée : {0}" -f $outputFile)
Write-Host ("Total entrées : {0}" -f $finalList.Count)
if ($sample.Count -gt 0) {
    Write-Host 'Exemples :'
    foreach ($item in $sample) {
        Write-Host " - $item"
    }
}

$logObject = [ordered]@{
    ts           = (Get-Date).ToUniversalTime().ToString('o')
    stage        = 'seeds-build'
    input_path   = if (Test-Path $inputFile) { (Resolve-Path $inputFile).Path } else { $null }
    used_default = $usedDefault
    seeds        = $seedData.Count
    raw_tokens   = $rawTokens.Count
    base_entries = $baseCandidates.Count
    generated    = $finalList.Count
    output_path  = (Resolve-Path $outputFile).Path
    sample       = $sample
}

$logFile = Join-Path $logsDir ("seeds-build-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$logJson = ($logObject | ConvertTo-Json -Compress)
[System.IO.File]::AppendAllText($logFile, $logJson + [Environment]::NewLine, $encoding)

Write-Host ("[LOG] Rapport : {0}" -f $logFile)
