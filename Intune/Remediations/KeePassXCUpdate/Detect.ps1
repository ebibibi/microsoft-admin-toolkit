<#
.SYNOPSIS
    Intune Remediation detection: KeePassXC installed at the newest eligible upstream release.
.DESCRIPTION
    Non-compliant when KeePassXC is missing or older than the newest stable GitHub
    release that has passed the soak period. While an update waits for the app to
    close, this stays non-compliant on purpose: the device is not updated yet.
    Run as SYSTEM, 64-bit PowerShell.
    Keep $MinReleaseAgeDays and the shared functions identical in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleasesApi = 'https://api.github.com/repos/keepassxreboot/keepassxc/releases?per_page=10'
$MinReleaseAgeDays = 3

function Get-InstalledVersion {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'KeePassXC*' -and $_.DisplayVersion } |
        Sort-Object { [version]$_.DisplayVersion } -Descending | Select-Object -First 1
    if ($entry) { return [version]$entry.DisplayVersion }
    return $null
}

function Select-TargetRelease {
    param([object[]]$Releases, [string]$Arch, [datetime]$Now, [int]$MinAgeDays)
    $labels = if ($Arch -eq 'ARM64') { @('ARM64') } else { @('x64', 'Win64') }
    $eligible = foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease) { continue }
        if ($release.tag_name -notmatch '^\d+\.\d+\.\d+$') { continue }
        $published = ([datetime]$release.published_at).ToUniversalTime()
        if ($published -gt $Now.ToUniversalTime().AddDays(-$MinAgeDays)) { continue }
        $names = $labels | ForEach-Object { "KeePassXC-$($release.tag_name)-$_.msi" }
        $asset = $release.assets |
            Where-Object { $names -contains $_.name -and $_.digest -match '^sha256:[0-9a-f]{64}$' } |
            Select-Object -First 1
        if (-not $asset) { continue }
        [pscustomobject]@{
            Version = [version]$release.tag_name
            Name    = $asset.name
            Url     = $asset.browser_download_url
            Sha256  = $asset.digest.Substring(7)
        }
    }
    return $eligible | Sort-Object Version -Descending | Select-Object -First 1
}

try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 60
    $target = Select-TargetRelease -Releases $releases -Arch $env:PROCESSOR_ARCHITECTURE `
        -Now (Get-Date) -MinAgeDays $MinReleaseAgeDays
    if (-not $target) { Write-Output 'No eligible KeePassXC release found.'; exit 1 }
    $installed = Get-InstalledVersion
    if (-not $installed) { Write-Output "KeePassXC not installed (target $($target.Version))."; exit 1 }
    if ($installed -lt $target.Version) {
        Write-Output "KeePassXC $installed is older than $($target.Version)."
        exit 1
    }
    Write-Output "KeePassXC $installed is current (newest eligible $($target.Version))."
    exit 0
}
catch { Write-Output "Detection error: $($_.Exception.Message)"; exit 1 }
