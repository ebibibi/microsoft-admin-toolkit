<#
.SYNOPSIS
    Intune Remediation: install or upgrade winget packages in user scope.
.DESCRIPTION
    Installs missing packages with --scope user (no elevation needed for a
    standard user) and upgrades installed ones. Run as the logged-on user
    (runAsAccount = user), 64-bit PowerShell. Keep $Packages identical in
    Detect.ps1.
#>
$ErrorActionPreference = 'Stop'

$Packages = @('Git.Git', 'Anthropic.ClaudeCode', 'OpenAI.Codex')
$CommonArgs = @('--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
# winget result codes treated as success.
$AlreadyInstalled = -1978335135   # APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
$NoUpgrade = -1978335189          # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE

try {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget not available for this user (App Installer missing).'
    }
    $done = @()
    $failed = @()
    foreach ($id in $Packages) {
        & winget.exe list --id $id --exact --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & winget.exe upgrade --id $id @CommonArgs | Out-Null
            $action = 'upgrade'
        }
        else {
            & winget.exe install --id $id --scope user @CommonArgs | Out-Null
            $action = 'install'
        }
        $code = $LASTEXITCODE
        if ($code -in 0, $AlreadyInstalled, $NoUpgrade) { $done += "$id ($action)" }
        else { $failed += "$id ($action exit $code)" }
    }
    if ($failed.Count) {
        Write-Output ("OK: $($done -join ', '); failed: $($failed -join ', ')")
        exit 1
    }
    Write-Output "OK: $($done -join ', ')"
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
