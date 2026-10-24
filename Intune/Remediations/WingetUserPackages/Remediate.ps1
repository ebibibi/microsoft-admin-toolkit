<#
.SYNOPSIS
    Intune Remediation: install or upgrade winget packages in user scope.
.DESCRIPTION
    Installs the Microsoft.WinGet.Client module for the user if needed, then
    installs missing packages (-Scope User, no elevation needed for a standard
    user) and upgrades outdated ones. When an upgrade returns
    NoApplicableUpgrade / NoApplicableInstallers (typically a copy installed by
    another installer), the available version is recorded in $StateFile so
    detection stops retrying it until a newer version appears.
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
    Keep $Packages and $StateFile identical in Detect.ps1.
#>
$ErrorActionPreference = 'Stop'

$Packages = @('Git.Git', 'Anthropic.ClaudeCode', 'OpenAI.Codex', 'Obsidian.Obsidian')
$StateFile = Join-Path $env:LOCALAPPDATA 'MySetup\winget-skipped-upgrades.json'
$NotApplicable = @('NoApplicableUpgrade', 'NoApplicableInstallers')

function Install-WinGetClientModule {
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
              Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}

function Save-SkippedUpgrade {
    param([string]$Id, [string]$Version)
    $state = @{}
    if (Test-Path $StateFile) {
        (Get-Content -Path $StateFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $state[$_.Name] = [string]$_.Value }
    }
    $state[$Id] = $Version
    New-Item -ItemType Directory -Path (Split-Path $StateFile) -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

try {
    Install-WinGetClientModule
    Import-Module Microsoft.WinGet.Client
    $report = @()
    $failed = $false
    foreach ($id in $Packages) {
        $pkg = Get-WinGetPackage -Id $id -MatchOption Equals | Select-Object -First 1
        if (-not $pkg) {
            $r = Install-WinGetPackage -Id $id -MatchOption Equals -Scope User -Mode Silent
            $action = 'install'
        }
        elseif ($pkg.IsUpdateAvailable) {
            $r = Update-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
            $action = 'upgrade'
        }
        else {
            $report += "$id=current"
            continue
        }
        $status = [string]$r.Status
        if ($status -eq 'Ok') {
            $report += "$id=$action ok"
        }
        elseif ($action -eq 'upgrade' -and $status -in $NotApplicable) {
            Save-SkippedUpgrade -Id $id -Version ([string]($pkg.AvailableVersions | Select-Object -First 1))
            $report += "$id=upgrade $status (skipped until newer)"
        }
        else {
            $report += "$id=$action $status (installer $($r.InstallerErrorCode), ext $($r.ExtendedErrorCode))"
            $failed = $true
        }
    }
    Write-Output ($report -join '; ')
    if ($failed) { exit 1 }
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
