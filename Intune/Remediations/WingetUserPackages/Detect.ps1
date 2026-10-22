<#
.SYNOPSIS
    Intune Remediation detection: winget packages installed and up to date for the user.
.DESCRIPTION
    Non-compliant when a package in $Packages is missing or winget reports an
    upgrade for it, so the remediation also keeps the packages updated.
    For tools not published in the Microsoft Store (Store apps are better
    assigned as Intune Microsoft Store apps). Run as the logged-on user
    (runAsAccount = user), 64-bit PowerShell. Keep $Packages identical in
    Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'

$Packages = @('Git.Git', 'Anthropic.ClaudeCode', 'OpenAI.Codex')
$CommonArgs = @('--exact', '--accept-source-agreements', '--disable-interactivity')

try {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Output 'winget not available for this user (App Installer missing).'
        exit 1
    }
    $missing = @()
    $outdated = @()
    foreach ($id in $Packages) {
        & winget.exe list --id $id @CommonArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { $missing += $id; continue }
        # Exit 0 with --upgrade-available means an upgrade was found.
        & winget.exe list --id $id --upgrade-available @CommonArgs | Out-Null
        if ($LASTEXITCODE -eq 0) { $outdated += $id }
    }
    if ($missing.Count -or $outdated.Count) {
        Write-Output ("Missing: $($missing -join ', '); upgrade available: $($outdated -join ', ')")
        exit 1
    }
    Write-Output "Installed and current: $($Packages -join ', ')"
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
