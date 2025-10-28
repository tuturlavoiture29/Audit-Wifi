[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$In,

    [Parameter(Mandatory = $true)]
    [string]$Out
)

# Script de conversion de captures en format Hashcat 22000.

function Get-ToolPath {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$PreferredPaths = @()
    )

    foreach ($path in $PreferredPaths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    try {
        $cmd = Get-Command -Name $Executable -ErrorAction Stop
        if ($cmd.Path) {
            return $cmd.Path
        }
    } catch {
        return $null
    }

    return $null
}

function Initialize-LogFile {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    $repoRoot = Split-Path -Parent $ScriptRoot
    $logDir = Join-Path -Path $repoRoot -ChildPath 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $logPath = Join-Path -Path $logDir -ChildPath ("convert_capture-${timestamp}.jsonl")
    return $logPath
}

function Write-LogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][hashtable]$Entry
    )

    if (-not $Entry.ContainsKey('stage')) {
        $Entry.stage = 'convert'
    }

    $json = $Entry | ConvertTo-Json -Compress
    Add-Content -Path $LogPath -Value $json
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Initialize-LogFile -ScriptRoot $scriptRoot

# Préparation des répertoires.
if (-not (Test-Path -LiteralPath $Out)) {
    try {
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
    } catch {
        Write-Error "Impossible de créer le dossier de sortie : $Out"
        exit 2
    }
} elseif (-not (Test-Path -LiteralPath $Out -PathType Container)) {
    Write-Error "Le chemin de sortie n'est pas un dossier : $Out"
    exit 2
}

# Recherche des fichiers d'entrée (.pcap, .pcapng).
$inputItems = @()
if (Test-Path -LiteralPath $In -PathType Container) {
    $inputItems = Get-ChildItem -Path $In -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.pcap', '.pcapng') }
} else {
    try {
        $inputItems = Get-ChildItem -Path $In -File -ErrorAction Stop | Where-Object { $_.Extension.ToLowerInvariant() -in @('.pcap', '.pcapng') }
    } catch {
        # Peut-être un motif générique.
        $inputItems = Get-ChildItem -Path $In -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in @('.pcap', '.pcapng') }
    }
}

if (-not $inputItems -or $inputItems.Count -eq 0) {
    Write-Error "Aucun fichier de capture trouvé pour : $In"
    exit 2
}

$hcxpcapngtoolPath = Get-ToolPath -Executable 'hcxpcapngtool.exe' -PreferredPaths @('C:\\Tools\\hcxtools\\hcxpcapngtool.exe')
$aircrackPath = Get-ToolPath -Executable 'aircrack-ng.exe'
$hcxhash2capPath = Get-ToolPath -Executable 'hcxhash2cap.exe' -PreferredPaths @('C:\\Tools\\hcxtools\\hcxhash2cap.exe')

$successCount = 0

foreach ($item in $inputItems) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
    $outPath = Join-Path -Path $Out -ChildPath ("${baseName}.22000")
    $logCommon = @{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        stage     = 'convert'
        src       = $item.FullName
        dst       = $outPath
        digests   = 0
        duration_ms = 0
        tool      = $null
    }

    if (Test-Path -LiteralPath $outPath) {
        Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
    }

    if ($hcxpcapngtoolPath) {
        $logCommon.tool = 'hcxpcapngtool'
        $output = & $hcxpcapngtoolPath '-o' $outPath $item.FullName 2>&1
        $exitCode = $LASTEXITCODE

        $stopwatch.Stop()
        $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)

        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $outPath)) {
            $outInfo = Get-Item -LiteralPath $outPath
            if ($outInfo.Length -gt 0) {
                $digestCount = (Get-Content -LiteralPath $outPath | Measure-Object -Line).Lines
                if ($digestCount -gt 0) {
                    $logCommon.digests = $digestCount
                    $logCommon.result = 'ok'
                    Write-LogEntry -LogPath $logFile -Entry $logCommon
                    $successCount++
                    continue
                }
            }
        }

        if (Test-Path -LiteralPath $outPath) {
            Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
        }

        $logCommon.error = 'conversion_failed'
        if ($output) {
            $logCommon.details = ($output -join "`n")
        }
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Write-Warning "Echec de conversion via hcxpcapngtool pour $($item.FullName)"
        continue
    }

    if (-not $aircrackPath) {
        $stopwatch.Stop()
        $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        $logCommon.tool = 'aircrack-ng'
        $logCommon.error = 'tool_missing'
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Write-Warning "aircrack-ng.exe introuvable pour traiter $($item.FullName)"
        continue
    }

    $logCommon.tool = if ($hcxhash2capPath) { 'aircrack-ng+hcxhash2cap' } else { 'aircrack-ng' }
    $baseOutput = Join-Path -Path $Out -ChildPath $baseName
    $hccapxPath = "${baseOutput}.hccapx"

    if (Test-Path -LiteralPath $hccapxPath) {
        Remove-Item -LiteralPath $hccapxPath -Force -ErrorAction SilentlyContinue
    }

    $aircrackOutput = & $aircrackPath '-J' $baseOutput $item.FullName 2>&1
    $aircrackCode = $LASTEXITCODE

    if ($aircrackCode -ne 0 -or -not (Test-Path -LiteralPath $hccapxPath)) {
        $stopwatch.Stop()
        $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        $logCommon.error = 'aircrack_failed'
        if ($aircrackOutput) {
            $logCommon.details = ($aircrackOutput -join "`n")
        }
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Write-Warning "Echec de aircrack-ng pour $($item.FullName)"
        continue
    }

    if (-not $hcxhash2capPath) {
        $stopwatch.Stop()
        $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        $logCommon.error = 'tool_missing'
        $logCommon.details = 'hcxhash2cap.exe requis pour convertir .hccapx vers .22000'
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Remove-Item -LiteralPath $hccapxPath -Force -ErrorAction SilentlyContinue
        Write-Warning "hcxhash2cap.exe introuvable pour convertir $($item.FullName)"
        continue
    }

    if (Test-Path -LiteralPath $outPath) {
        Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
    }

    $hashConvertOutput = & $hcxhash2capPath '-i' $hccapxPath '-o' $outPath 2>&1
    $hashConvertCode = $LASTEXITCODE

    if ($hashConvertCode -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
        $stopwatch.Stop()
        $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        $logCommon.error = 'hcxhash2cap_failed'
        if ($hashConvertOutput) {
            $logCommon.details = ($hashConvertOutput -join "`n")
        }
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Remove-Item -LiteralPath $hccapxPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $outPath) {
            Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
        }
        Write-Warning "Echec de hcxhash2cap pour $($item.FullName)"
        continue
    }

    Remove-Item -LiteralPath $hccapxPath -Force -ErrorAction SilentlyContinue

    $outInfo = Get-Item -LiteralPath $outPath
    $digestCount = 0
    if ($outInfo.Length -gt 0) {
        $digestCount = (Get-Content -LiteralPath $outPath | Measure-Object -Line).Lines
    }

    $stopwatch.Stop()
    $logCommon.duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)

    if ($digestCount -gt 0) {
        $logCommon.digests = $digestCount
        $logCommon.result = 'ok'
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        $successCount++
    } else {
        if (Test-Path -LiteralPath $outPath) {
            Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
        }
        $logCommon.error = 'empty_output'
        Write-LogEntry -LogPath $logFile -Entry $logCommon
        Write-Warning "Fichier 22000 vide pour $($item.FullName)"
    }
}

if ($successCount -gt 0) {
    exit 0
}

exit 2
