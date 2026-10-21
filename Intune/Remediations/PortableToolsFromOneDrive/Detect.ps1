<#
.SYNOPSIS
    Intune Remediation detection: portable tools copied from the personal OneDrive.
.DESCRIPTION
    For each tool in $Tools, compliant when one of its executables exists under
    %LOCALAPPDATA%\Programs\<Name> and a Start menu shortcut exists.
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
    Keep $Tools identical in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'

$Tools = @(
    @{ Name = 'KeePass'; Executables = @('KeePass.exe', 'KeePassXC.exe') }
)
$ProgramsDir = Join-Path $env:LOCALAPPDATA 'Programs'
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Portable'

try {
    $missing = @()
    foreach ($tool in $Tools) {
        $dir = Join-Path $ProgramsDir $tool.Name
        $exe = $tool.Executables | Where-Object { Test-Path (Join-Path $dir $_) } | Select-Object -First 1
        if (-not $exe -or -not (Test-Path (Join-Path $StartMenuDir "$($tool.Name).lnk"))) {
            $missing += $tool.Name
        }
    }
    if ($missing.Count -gt 0) {
        Write-Output ('Not installed: ' + ($missing -join ', '))
        exit 1
    }
    Write-Output 'All portable tools present.'
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
