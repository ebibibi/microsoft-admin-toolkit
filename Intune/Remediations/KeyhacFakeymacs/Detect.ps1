<#
.SYNOPSIS
    Intune Remediation detection: Keyhac + Fakeymacs ready for the signed-in user.
.DESCRIPTION
    Compliant when all of these hold:
      - keyhac.exe exists under the per-user install folder
      - config.py there is Fakeymacs
      - config_personal.py makes Fakeymacs use the Right Ctrl key
      - a Startup-folder shortcut launches Keyhac at sign-in
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
    Keep the constants identical in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Keyhac'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Keyhac.lnk'
$CtrlSide = 'R'

function Get-CtrlSide {
    param([string]$Path)
    # The last top-level assignment wins when Fakeymacs executes the section.
    $text = [IO.File]::ReadAllText($Path)
    $found = [regex]::Matches($text, '(?m)^fc\.side_of_ctrl_key\s*=\s*"([^"]*)"')
    if ($found.Count -eq 0) { return $null }
    return $found[$found.Count - 1].Groups[1].Value
}

try {
    $problems = @()
    if (-not (Test-Path (Join-Path $InstallDir 'keyhac.exe'))) { $problems += 'keyhac.exe missing' }

    $config = Join-Path $InstallDir 'config.py'
    if (-not (Test-Path $config) -or -not (Select-String -Path $config -Pattern '^fakeymacs_version' -Quiet)) {
        $problems += 'config.py is not Fakeymacs'
    }

    $personal = Join-Path $InstallDir 'config_personal.py'
    if (-not (Test-Path $personal)) {
        $problems += 'config_personal.py missing'
    }
    elseif ((Get-CtrlSide -Path $personal) -ne $CtrlSide) {
        $problems += "side_of_ctrl_key is not $CtrlSide"
    }

    if (-not (Test-Path $StartupLink)) { $problems += 'Startup shortcut missing' }

    if ($problems.Count -gt 0) {
        Write-Output ('Keyhac not ready: ' + ($problems -join '; '))
        exit 1
    }
    Write-Output "Keyhac + Fakeymacs ready (Ctrl side $CtrlSide)."
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
