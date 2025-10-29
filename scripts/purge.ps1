<#!
.SYNOPSIS
    Perform a controlled purge of generated artefacts.
.DESCRIPTION
    Allows the operator to selectively purge data from well-known working
    directories (captures/, hashes/, logs/, reports/). The script requires a
    double confirmation before deleting and records a purge log inside the
    reports directory.
#>
[CmdletBinding()]
param(
    [string[]]$Targets
)

$root = Split-Path -Parent $PSScriptRoot
$directories = [ordered]@{
    captures = Join-Path $root 'captures'
    hashes   = Join-Path $root 'hashes'
    logs     = Join-Path $root 'logs'
    reports  = Join-Path $root 'reports'
}

function Resolve-Selection {
    param(
        [string[]]$Requested
    )

    if ($Requested -and $Requested.Count -gt 0) {
        if ($Requested -contains 'all') {
            return $directories.Keys
        }
        $unknown = $Requested | Where-Object { -not $directories.Contains($_) }
        if ($unknown) {
            throw "Unknown target(s): $($unknown -join ', '). Valid options: $($directories.Keys -join ', ')"
        }
        return $Requested
    }

    Write-Host 'Select the directories to purge:'
    $index = 1
    foreach ($key in $directories.Keys) {
        Write-Host ("  [{0}] {1} -> {2}" -f $index, $key, $directories[$key])
        $index++
    }
    Write-Host '  [A] All of the above'

    $selection = Read-Host 'Enter comma-separated choices (e.g. 1,3 or A)'
    if ([string]::IsNullOrWhiteSpace($selection)) {
        return @()
    }

    $selection = $selection.Trim()
    if ($selection -match '^[Aa]$') {
        return $directories.Keys
    }

    $parts = $selection.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $selectedKeys = @()
    foreach ($part in $parts) {
        if ($part -match '^[0-9]+$') {
            $idx = [int]$part
            if ($idx -ge 1 -and $idx -le $directories.Count) {
                $selectedKeys += $directories.Keys[$idx - 1]
            }
            else {
                Write-Warning "Ignoring out-of-range option: $part"
            }
        }
        else {
            $normalized = $part.ToLowerInvariant()
            if ($directories.Contains($normalized)) {
                $selectedKeys += $normalized
            }
            else {
                Write-Warning "Ignoring unknown option: $part"
            }
        }
    }
    return $selectedKeys | Select-Object -Unique
}

try {
    $selectedTargets = Resolve-Selection -Requested $Targets
}
catch {
    Write-Error $_
    exit 1
}

if (-not $selectedTargets -or $selectedTargets.Count -eq 0) {
    Write-Host 'No directories selected. Exiting without changes.'
    exit 0
}

Write-Host 'You have chosen to purge:'
foreach ($target in $selectedTargets) {
    Write-Host (" - {0}" -f $target)
}

$firstConfirmation = Read-Host 'Type YES to confirm this selection'
if ($firstConfirmation -ne 'YES') {
    Write-Host 'Confirmation failed. No changes were made.'
    exit 0
}

$finalConfirmation = Read-Host 'Final confirmation required. Type PURGE to proceed'
if ($finalConfirmation -ne 'PURGE') {
    Write-Host 'Final confirmation failed. No changes were made.'
    exit 0
}

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$reportsPath = $directories['reports']
if (-not (Test-Path $reportsPath -PathType Container)) {
    New-Item -ItemType Directory -Path $reportsPath -Force | Out-Null
}
$logPath = Join-Path $reportsPath ("purge-log-{0}.txt" -f $timestamp)
New-Item -ItemType File -Path $logPath -Force | Out-Null

Add-Content -Path $logPath -Value "Purge started at $(Get-Date -Format u)"
Add-Content -Path $logPath -Value "Selected targets: $($selectedTargets -join ', ')"
Add-Content -Path $logPath -Value ''

foreach ($target in $selectedTargets) {
    $path = $directories[$target]
    Add-Content -Path $logPath -Value ("Processing {0} -> {1}" -f $target, $path)

    if (-not (Test-Path $path -PathType Container)) {
        Add-Content -Path $logPath -Value '  Directory not found. Skipped.'
        Write-Warning "Directory not found for target '$target': $path"
        Add-Content -Path $logPath -Value ''
        continue
    }

    $items = Get-ChildItem -Path $path -Force -Recurse -ErrorAction SilentlyContinue
    $fileCount = ($items | Where-Object { -not $_.PSIsContainer }).Count
    $dirCount = ($items | Where-Object { $_.PSIsContainer }).Count

    if ($items.Count -eq 0) {
        Add-Content -Path $logPath -Value '  Directory already empty.'
        Add-Content -Path $logPath -Value ''
        continue
    }

    try {
        Remove-Item -Path (Join-Path $path '*') -Recurse -Force -ErrorAction Stop
        Add-Content -Path $logPath -Value "  Removed files: $fileCount"
        Add-Content -Path $logPath -Value "  Removed directories: $dirCount"
        Add-Content -Path $logPath -Value '  Status: Success'
    }
    catch {
        $errorMessage = $_.Exception.Message
        Add-Content -Path $logPath -Value "  Status: Failed - $errorMessage"
        Write-Error "Failed to purge '$target': $errorMessage"
    }
    Add-Content -Path $logPath -Value ''
}

Add-Content -Path $logPath -Value "Purge completed at $(Get-Date -Format u)"
Write-Host "Purge completed. Details recorded in $logPath"
