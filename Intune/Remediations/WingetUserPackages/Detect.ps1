<#
.SYNOPSIS
    Intune Remediation detection: winget packages installed and up to date for the user.
.DESCRIPTION
    Uses the Microsoft.WinGet.Client module (object output) instead of parsing
    winget.exe exit codes. Non-compliant when a package in $Packages is missing
    or has an available upgrade, so the hourly run also keeps packages current.
    An upgrade that the remediation recorded as not applicable (for example the
    package was installed by another installer) is ignored until a newer
    version appears. The output lists installed/available versions.
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
    Keep $Packages and $StateFile identical in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'

$Packages = @('Git.Git', 'Anthropic.ClaudeCode', 'OpenAI.Codex', 'Obsidian.Obsidian')
$StateFile = Join-Path $env:LOCALAPPDATA 'MySetup\winget-skipped-upgrades.json'

function Get-SkippedUpgrades {
    $skipped = @{}
    if (Test-Path $StateFile) {
        (Get-Content -Path $StateFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $skipped[$_.Name] = [string]$_.Value }
    }
    return $skipped
}

try {
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-Output 'Microsoft.WinGet.Client module not installed.'
        exit 1
    }
    Import-Module Microsoft.WinGet.Client
    $skipped = Get-SkippedUpgrades
    $report = @()
    $needed = $false
    foreach ($id in $Packages) {
        $pkg = Get-WinGetPackage -Id $id -MatchOption Equals | Select-Object -First 1
        if (-not $pkg) {
            $report += "$id=missing"
            $needed = $true
            continue
        }
        $latest = [string]($pkg.AvailableVersions | Select-Object -First 1)
        if ($pkg.IsUpdateAvailable -and $skipped[$id] -ne $latest) {
            $report += "$id=$($pkg.InstalledVersion)->$latest"
            $needed = $true
        }
        elseif ($pkg.IsUpdateAvailable) {
            $report += "$id=$($pkg.InstalledVersion) (upgrade $latest not applicable)"
        }
        else {
            $report += "$id=$($pkg.InstalledVersion)"
        }
    }
    Write-Output ($report -join '; ')
    if ($needed) { exit 1 }
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
