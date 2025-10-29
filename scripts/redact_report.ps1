<#!
.SYNOPSIS
    Redact sensitive information from a report before sharing.
.DESCRIPTION
    Replaces SSID and BSSID values with deterministic truncated hashes and masks
    personal filesystem paths to protect user privacy when exporting reports.
.PARAMETER InputPath
    Path to the report file that should be anonymised.
.PARAMETER OutputPath
    Optional path to write the redacted report. Defaults to creating a
    "-redacted" sibling file when omitted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath
)

function Get-TruncatedHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter()]
        [int]$Length = 12
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hashBytes = $sha.ComputeHash($bytes)
        $hashString = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
        return $hashString.Substring(0, [Math]::Min($Length, $hashString.Length))
    }
    finally {
        $sha.Dispose()
    }
}

if (-not $OutputPath) {
    $directory = Split-Path -Parent $InputPath
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $extension = [System.IO.Path]::GetExtension($InputPath)
    $OutputPath = Join-Path $directory ("{0}-redacted{1}" -f $fileName, $extension)
}

$content = Get-Content -Path $InputPath -Raw

$ssidMap = @{}
$ssidRegex = [regex]'(?im)(SSID\s*[:=]\s*)([^\r\n]+)'
$content = $ssidRegex.Replace($content, {
    param($match)
    $prefix = $match.Groups[1].Value
    $value = $match.Groups[2].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        if (-not $ssidMap.ContainsKey($value)) {
            $ssidMap[$value] = "SSID-$(Get-TruncatedHash -Value $value)"
        }
        return $prefix + $ssidMap[$value]
    }
    return $match.Value
})

$bssidMap = @{}
$bssidRegex = [regex]'(?i)\b([0-9a-f]{2}(?:[:-][0-9a-f]{2}){5})\b'
$content = $bssidRegex.Replace($content, {
    param($match)
    $value = $match.Groups[1].Value
    if (-not $bssidMap.ContainsKey($value)) {
        $bssidMap[$value] = "BSSID-$(Get-TruncatedHash -Value $value)"
    }
    return $bssidMap[$value]
})

# Mask common personal filesystem paths.
$content = [regex]::Replace($content, '(?i)C:\\Users\\[^\\\s]+', 'C:\Users\<REDACTED>')
$content = [regex]::Replace($content, '(?i)/home/[^/\s]+', '/home/<REDACTED>')
$content = [regex]::Replace($content, '(?i)/Users/[^/\s]+', '/Users/<REDACTED>')

Set-Content -Path $OutputPath -Value $content
Write-Host "Redacted report written to: $OutputPath"
