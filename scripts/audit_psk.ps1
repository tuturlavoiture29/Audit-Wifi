[CmdletBinding()]
param(
    [string]$Hashes,

    [string]$SSIDMap,

    [ValidateSet('gpu', 'cpu')]
    [string]$Profile,

    [ValidateRange(1, 1440)]
    [int]$TimeboxPerStageMin,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$defaultConfigPath = Join-Path (Join-Path $projectRoot 'config') 'defaults.yml'

function Resolve-OptionalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return (Resolve-Path -Path $Path -ErrorAction Stop).Path
    }
    catch {
        return $Path
    }
}

function Get-ConfigProperty {
    param(
        $Config,
        [string[]]$Path
    )

    if ($null -eq $Config) { return $null }
    $current = $Config
    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
            continue
        }
        $props = $current.PSObject.Properties
        if ($props.Name -notcontains $segment) { return $null }
        $current = $current.$segment
    }
    return $current
}

function ConvertTo-StringArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $result = @()
        foreach ($item in $Value) {
            if ($null -ne $item) { $result += [string]$item }
        }
        return $result
    }
    return @([string]$Value)
}

function Resolve-ConfigPath {
    param(
        [string]$PathValue,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([IO.Path]::IsPathRooted($PathValue)) {
        return Resolve-OptionalPath -Path $PathValue
    }
    if ($BasePath) {
        return Resolve-OptionalPath -Path (Join-Path $BasePath $PathValue)
    }
    return Resolve-OptionalPath -Path $PathValue
}

$configPath = if ($ConfigPath) { $ConfigPath } else { $defaultConfigPath }
$configPath = Resolve-OptionalPath -Path $configPath
$configSource = 'cli'
$configData = $null

$yamlCmd = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue

if ($configPath -and (Test-Path $configPath)) {
    if (-not $yamlCmd) {
        Write-Warning "ConvertFrom-Yaml indisponible, impossible de charger '$configPath'"
    }
    else {
        try {
            $rawConfig = Get-Content -Path $configPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($rawConfig)) {
                $configData = $rawConfig | ConvertFrom-Yaml
                $configSource = 'yaml'
            }
        }
        catch {
            Write-Warning "Impossible de charger le fichier de configuration '$configPath': $_"
        }
    }
}

$root = Get-ConfigProperty -Config $configData -Path @('paths', 'root')
if (-not $root) { $root = 'C:\Audit-Wifi' }
$root = Resolve-OptionalPath -Path $root

$hashesPattern = if ($Hashes) { $Hashes } else { Get-ConfigProperty -Config $configData -Path @('defaults', 'hashes') }
if (-not $hashesPattern) {
    Write-Error 'Aucun chemin de hashes fourni (paramètre -Hashes ou configuration defaults.hashes).'
    exit 4
}

$SSIDMap = if ($SSIDMap) { $SSIDMap } else { Get-ConfigProperty -Config $configData -Path @('defaults', 'ssid_map') }

$potfile = Get-ConfigProperty -Config $configData -Path @('paths', 'potfile')
if (-not $potfile) { $potfile = Join-Path $root 'potfile.txt' }
$potfile = Resolve-ConfigPath -PathValue $potfile -BasePath $root

$logsDir = Get-ConfigProperty -Config $configData -Path @('paths', 'logs')
if (-not $logsDir) { $logsDir = Join-Path $root 'logs' }
$logsDir = Resolve-ConfigPath -PathValue $logsDir -BasePath $root

$reportsDir = Get-ConfigProperty -Config $configData -Path @('paths', 'reports')
if (-not $reportsDir) { $reportsDir = Join-Path $root 'reports' }
$reportsDir = Resolve-ConfigPath -PathValue $reportsDir -BasePath $root

$hashcatPath = Get-ConfigProperty -Config $configData -Path @('paths', 'hashcat')
if (-not $hashcatPath) { $hashcatPath = 'C:\Tools\hashcat\hashcat.exe' }
$hashcatPath = Resolve-ConfigPath -PathValue $hashcatPath -BasePath $root

$profileFromConfig = Get-ConfigProperty -Config $configData -Path @('defaults', 'profile')
if (-not $Profile) { $Profile = $profileFromConfig }
if (-not $Profile) { $Profile = 'gpu' }
if ($Profile) { $Profile = $Profile.ToLowerInvariant() }
if (@('gpu', 'cpu') -notcontains $Profile) {
    Write-Error "Profil non supporté: $Profile"
    exit 5
}

$timeboxConfig = Get-ConfigProperty -Config $configData -Path @('timebox', 'per_stage_min')
if (-not $TimeboxPerStageMin) { $TimeboxPerStageMin = $timeboxConfig }
if (-not $TimeboxPerStageMin) { $TimeboxPerStageMin = 15 }
$TimeboxPerStageMin = [int]$TimeboxPerStageMin
if ($TimeboxPerStageMin -lt 1 -or $TimeboxPerStageMin -gt 1440) {
    Write-Error "TimeboxPerStageMin doit être compris entre 1 et 1440 (valeur: $TimeboxPerStageMin)"
    exit 6
}

New-Item -ItemType Directory -Force -Path $logsDir, $reportsDir | Out-Null
if (-not (Test-Path $potfile)) {
    New-Item -ItemType File -Force -Path $potfile | Out-Null
}

if (-not (Test-Path $hashcatPath)) {
    Write-Error "hashcat introuvable: $hashcatPath"
    exit 2
}

$hashcatDir  = Split-Path $hashcatPath -Parent
$profileArgs = @()

$profileConfigArgs = Get-ConfigProperty -Config $configData -Path @('profiles', $Profile)
if ($profileConfigArgs) {
    if ($profileConfigArgs -is [System.Collections.IEnumerable] -and -not ($profileConfigArgs -is [string])) {
        $profileArgs += $profileConfigArgs
    }
    else {
        $profileArgs += @([string]$profileConfigArgs)
    }
}
elseif ($Profile -eq 'cpu') {
    $profileArgs += @('--backend-ignore-opencl', '--opencl-device-types', '1')
}

$runtimeSeconds = $TimeboxPerStageMin * 60

$listsRoot = Get-ConfigProperty -Config $configData -Path @('paths', 'lists', 'root')
if (-not $listsRoot) {
    $listsCandidate = Get-ConfigProperty -Config $configData -Path @('paths', 'lists')
    if ($listsCandidate -is [string]) { $listsRoot = $listsCandidate }
}
if (-not $listsRoot) { $listsRoot = Join-Path $root 'lists' }

if ($SSIDMap) {
    $SSIDMap = Resolve-ConfigPath -PathValue $SSIDMap -BasePath $listsRoot
}

$rulesRoot = Get-ConfigProperty -Config $configData -Path @('paths', 'rules', 'root')
if (-not $rulesRoot) {
    $rulesCandidate = Get-ConfigProperty -Config $configData -Path @('paths', 'rules')
    if ($rulesCandidate -is [string]) { $rulesRoot = $rulesCandidate }
}
if (-not $rulesRoot) { $rulesRoot = Join-Path $root 'rules' }

function Get-ReadableHashes {
    param([string]$Pattern)

    $items = @()
    try {
        $items = Get-ChildItem -Path $Pattern -File -ErrorAction Stop
    }
    catch {
        Write-Warning "Impossible de lister les hashes via '$Pattern': $_"
    }

    return $items | Where-Object { $_.Extension -eq '.22000' -and $_.Length -gt 0 }
}

function Load-SSIDMap {
    param([string]$Path)

    $mapping = @{}
    if (-not $Path) { return $mapping }
    if (-not (Test-Path $Path)) {
        Write-Warning "Fichier SSIDMap introuvable: $Path"
        return $mapping
    }

    try {
        $rows = Import-Csv -Path $Path
    }
    catch {
        Write-Warning "Lecture SSIDMap impossible ($Path): $_"
        return $mapping
    }

    foreach ($row in $rows) {
        $key = $null
        foreach ($candidate in @('hash', 'file', 'path', 'handshake', 'bssid')) {
            if ($row.PSObject.Properties.Name -contains $candidate -and -not [string]::IsNullOrWhiteSpace($row.$candidate)) {
                $key = $row.$candidate
                break
            }
        }
        if ($null -eq $key) { continue }
        $key = [IO.Path]::GetFileNameWithoutExtension($key)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        $value = $null
        foreach ($candidate in @('target', 'ssid', 'name', 'label')) {
            if ($row.PSObject.Properties.Name -contains $candidate -and -not [string]::IsNullOrWhiteSpace($row.$candidate)) {
                $value = $row.$candidate
                break
            }
        }
        if ($null -eq $value) { continue }
        $mapping[$key] = $value
    }

    return $mapping
}

function Get-ShowPlaintexts {
    param([string]$HashPath)

    $args = @('--show', '-m', '22000', $HashPath, '--potfile-path', $potfile)
    $output = & $hashcatPath @args 2>&1
    $plain = @()
    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -like 'No hashes found*') { continue }
        $idx = $line.LastIndexOf(':')
        if ($idx -ge 0 -and $idx -lt $line.Length - 1) {
            $plain += $line.Substring($idx + 1)
        }
    }
    return $plain
}

function Parse-HashcatStatus {
    param([string[]]$Lines)

    $status = $null
    foreach ($line in $Lines) {
        if (-not $line) { continue }
        if ($line.TrimStart().StartsWith('{')) {
            try {
                $status = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }
        }
    }
    if ($null -eq $status) { return $null }

    $speed = $null
    $progressRatio = $null

    if ($status.PSObject.Properties.Name -contains 'speed') {
        $rawSpeed = $status.speed
        if ($rawSpeed -is [System.Collections.IEnumerable] -and -not ($rawSpeed -is [string])) {
            $sum = 0.0
            foreach ($entry in $rawSpeed) {
                if ($entry -is [System.ValueType]) {
                    $sum += [double]$entry
                }
                elseif ($entry.PSObject.Properties.Name -contains 'value') {
                    $sum += [double]$entry.value
                }
                elseif ($entry.PSObject.Properties.Name -contains 'all') {
                    $sum += [double]$entry.all
                }
            }
            if ($sum -gt 0) { $speed = $sum }
        }
        elseif ($rawSpeed.PSObject.Properties.Name -contains 'all') {
            $speed = [double]$rawSpeed.all
        }
        elseif ($rawSpeed -is [System.ValueType]) {
            $speed = [double]$rawSpeed
        }
    }

    if ($status.PSObject.Properties.Name -contains 'progress') {
        $rawProgress = $status.progress
        if ($rawProgress -is [System.Collections.IList] -and $rawProgress.Count -ge 2) {
            $total = [double]$rawProgress[1]
            if ($total -gt 0) {
                $progressRatio = [double]$rawProgress[0] / $total
            }
        }
        elseif ($status.PSObject.Properties.Name -contains 'progress_relative') {
            $progressRatio = [double]$status.progress_relative
        }
    }

    return [pscustomobject]@{
        Speed    = $speed
        Progress = $progressRatio
    }
}

function Write-StageLog {
    param(
        [string]$Stage,
        [string]$Target,
        [int]$DurationMs,
        [int]$Recovered,
        $Status,
        [bool]$Skipped = $false,
        [hashtable]$Extra = $null
    )

    $logPath = Join-Path $logsDir ("audit_psk-${Stage}.jsonl")
    $record = [ordered]@{
        ts          = (Get-Date).ToUniversalTime().ToString('o')
        stage       = $Stage
        target      = $Target
        duration_ms = $DurationMs
        recovered   = $Recovered
        skipped     = $Skipped
        hs          = $null
        progress    = $null
    }
    if ($Status) {
        if ($Status.Speed) { $record.hs = [math]::Round($Status.Speed, 2) }
        if ($Status.Progress) { $record.progress = [math]::Round($Status.Progress, 4) }
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) {
            $record[$key] = $Extra[$key]
        }
    }
    $record | ConvertTo-Json -Compress | Out-File -FilePath $logPath -Append -Encoding utf8
}

Write-StageLog -Stage 'config-load' -Target '' -DurationMs 0 -Recovered 0 -Status $null -Skipped:$false -Extra $configLogExtra

function Invoke-HashcatCommand {
    param(
        [string]$SessionName,
        [string[]]$Arguments,
        [int]$RuntimeSeconds
    )

    $restorePath = Join-Path $hashcatDir ("${SessionName}.restore")
    $start = Get-Date
    $output = @()
    if (Test-Path $restorePath) {
        $restoreArgs = @('--restore', '--session', $SessionName)
        $output = & $hashcatPath @profileArgs @restoreArgs 2>&1
    }
    else {
        $baseArgs = @('-m', '22000', '--potfile-path', $potfile, '--session', $SessionName,
            '--status', '--status-json', '--status-timer', '15', '--runtime-limit', $RuntimeSeconds,
            '--logfile-disable')
        $output = & $hashcatPath @profileArgs @baseArgs @Arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    $duration = [int][math]::Round((Get-Date - $start).TotalMilliseconds)
    $status = Parse-HashcatStatus -Lines $output

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Output     = $output
        DurationMs = $duration
        Status     = $status
    }
}

function SanitizeMask {
    param([string]$Mask)
    $mask = $Mask.Replace('?', 'Q').Replace('*', 'S').Replace(':', 'C').Replace('\', '_')
    return $mask
}

$hashFiles = Get-ReadableHashes -Pattern $hashesPattern
if (-not $hashFiles -or $hashFiles.Count -eq 0) {
    Write-Warning "Aucun hash 22000 lisible via '$hashesPattern'"
    exit 1
}

$ssidLookup = Load-SSIDMap -Path $SSIDMap

$targetedCandidates = ConvertTo-StringArray (Get-ConfigProperty -Config $configData -Path @('paths', 'lists', 'targeted'))
if ($targetedCandidates.Count -eq 0) {
    $targetedCandidates = @('targeted_build.txt', 'targeted_arthur.txt', 'context.txt')
}
$targetedCandidates = @(
    foreach ($candidate in $targetedCandidates) {
        $resolved = Resolve-ConfigPath -PathValue $candidate -BasePath $listsRoot
        if ($resolved) { $resolved }
    }
)
$targetedWordlist = $null
foreach ($candidate in $targetedCandidates) {
    if (Test-Path $candidate) { $targetedWordlist = $candidate; break }
}

$numbersSuffixList = Get-ConfigProperty -Config $configData -Path @('paths', 'lists', 'numbers_suffix')
if (-not $numbersSuffixList) { $numbersSuffixList = 'numbers_suf.txt' }
$numbersSuffixList = Resolve-ConfigPath -PathValue $numbersSuffixList -BasePath $listsRoot

$smartTopList = Get-ConfigProperty -Config $configData -Path @('paths', 'lists', 'smart_top')
if (-not $smartTopList) { $smartTopList = 'smart-top.txt' }
$smartTopList = Resolve-ConfigPath -PathValue $smartTopList -BasePath $listsRoot

$rulesLite = Get-ConfigProperty -Config $configData -Path @('paths', 'rules', 'lite')
if (-not $rulesLite) { $rulesLite = 'rules-fr-lite.rule' }
$rulesLite = Resolve-ConfigPath -PathValue $rulesLite -BasePath $rulesRoot

$rulesPlus = Get-ConfigProperty -Config $configData -Path @('paths', 'rules', 'plus')
if (-not $rulesPlus) { $rulesPlus = 'fr_plus.rule' }
$rulesPlus = Resolve-ConfigPath -PathValue $rulesPlus -BasePath $rulesRoot

$masksStage3 = ConvertTo-StringArray (Get-ConfigProperty -Config $configData -Path @('masks', 'stage3'))
if ($masksStage3.Count -eq 0) {
    $masksStage3 = @('?d?d?d?d?d?d?d?d', '19?d?d?d?d', '20?d?d?d?d', '?d?d?d?d?d?d!')
}

$configLogExtra = [ordered]@{ source = $configSource }
if ($configPath) { $configLogExtra.config_path = $configPath }
$configLogExtra.hashes_pattern = $hashesPattern
if ($Profile) { $configLogExtra.profile = $Profile }
$configLogExtra.timebox_per_stage_min = $TimeboxPerStageMin
if ($masksStage3.Count -gt 0) { $configLogExtra.masks_stage3 = $masksStage3 }

$stages = @()
$stages += [pscustomobject]@{
    Name = 'S1'
    Builder = {
        param($hashPath)
        if (-not $targetedWordlist) { return @() }
        return @([pscustomobject]@{
            SessionSuffix = 'base'
            Arguments = @('-a', '0', $hashPath, $targetedWordlist)
        })
    }
}
$stages += [pscustomobject]@{
    Name = 'S2'
    Builder = {
        param($hashPath)
        if (-not $targetedWordlist -or -not (Test-Path $numbersSuffixList)) { return @() }
        return @([pscustomobject]@{
            SessionSuffix = 'combo'
            Arguments = @('-a', '1', $hashPath, $targetedWordlist, $numbersSuffixList)
        })
    }
}
$stages += [pscustomobject]@{
    Name = 'S3'
    Builder = {
        param($hashPath)
        $commands = @()
        foreach ($mask in $masksStage3) {
            $commands += [pscustomobject]@{
                SessionSuffix = 'mask-' + (SanitizeMask -Mask $mask)
                Arguments = @('-a', '3', $hashPath, $mask)
            }
        }
        return $commands
    }
}
$stages += [pscustomobject]@{
    Name = 'S4'
    Builder = {
        param($hashPath)
        if (-not (Test-Path $smartTopList)) { return @() }
        $args = @('-a', '0', $hashPath, $smartTopList)
        if (Test-Path $rulesPlus) {
            $args += @('-r', $rulesPlus)
        }
        elseif (Test-Path $rulesLite) {
            $args += @('-r', $rulesLite)
        }
        return @([pscustomobject]@{
            SessionSuffix = 'smart'
            Arguments = $args
        })
    }
}

$summaryRows = @()

Push-Location $hashcatDir
try {
    foreach ($hash in $hashFiles) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($hash.Name)
        $targetName = if ($ssidLookup.ContainsKey($baseName)) { $ssidLookup[$baseName] } else { $baseName }

        $known = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($plain in Get-ShowPlaintexts -HashPath $hash.FullName) {
            $null = $known.Add($plain)
        }

        $targetState = [ordered]@{
            Target        = $targetName
            Found         = $false
            Stage         = ''
            Guess         = ''
            TimeToSuccess = 0.0
            Elapsed       = 0.0
        }

        foreach ($stage in $stages) {
            $commands = & $stage.Builder $hash.FullName
            if (-not $commands -or $commands.Count -eq 0) {
                Write-StageLog -Stage $stage.Name -Target $targetName -DurationMs 0 -Recovered 0 -Status $null -Skipped $true
                continue
            }

            $stageDuration = 0
            $stageRecovered = 0
            $stageNewPlaintexts = @()
            $lastStatus = $null
            foreach ($command in $commands) {
                $sessionName = "${baseName}-${stage.Name}-${command.SessionSuffix}"
                $result = Invoke-HashcatCommand -SessionName $sessionName -Arguments $command.Arguments -RuntimeSeconds $runtimeSeconds
                $stageDuration += $result.DurationMs
                if ($result.Status) { $lastStatus = $result.Status }

                if ($result.ExitCode -gt 1) {
                    Write-Warning ("hashcat a retourne le code {0} pour {1} ({2})" -f $result.ExitCode, $hash.Name, $stage.Name)
                }

                foreach ($plain in Get-ShowPlaintexts -HashPath $hash.FullName) {
                    if ($known.Add($plain)) {
                        $stageRecovered += 1
                        $stageNewPlaintexts += $plain
                    }
                }

                if ($stageRecovered -gt 0) {
                    break
                }
            }

            Write-StageLog -Stage $stage.Name -Target $targetName -DurationMs $stageDuration -Recovered $stageRecovered -Status $lastStatus

            $targetState.Elapsed += ($stageDuration / 1000.0)
            if (-not $targetState.Found -and $stageRecovered -gt 0) {
                $targetState.Found = $true
                $targetState.Stage = $stage.Name
                if ($stageNewPlaintexts.Count -gt 0) {
                    $targetState.Guess = $stageNewPlaintexts[0]
                }
                $targetState.TimeToSuccess = $targetState.Elapsed
                break
            }
        }

        if (-not $targetState.Found) {
            $targetState.TimeToSuccess = $targetState.Elapsed
        }

        $summaryRows += [pscustomobject]@{
            target      = $targetState.Target
            found       = if ($targetState.Found) { 1 } else { 0 }
            stage       = if ($targetState.Found) { $targetState.Stage } else { '' }
            guess       = $targetState.Guess
            duration_s  = [math]::Round($targetState.TimeToSuccess, 2)
        }
    }
}
finally {
    Pop-Location
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$summaryPath = Join-Path $reportsDir ("summary-${timestamp}.csv")
$summaryRows | Export-Csv -NoTypeInformation -Encoding utf8 -Path $summaryPath

Write-Host "Résumé écrit: $summaryPath"
exit 0
