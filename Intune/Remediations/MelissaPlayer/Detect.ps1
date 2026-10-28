<#
.SYNOPSIS
    Intune Remediation detection: is Melissa (music practice player) installed?
.DESCRIPTION
    Compliant when the Inno Setup uninstall entry reports at least $MinVersion
    and Melissa.exe exists in the install folder. Run as SYSTEM, 64-bit.
    Keep $AppId and $MinVersion identical to $AppId and $Version in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'
$AppId = '{907F3FD5-AADA-4711-A93D-EF935B4AC39F}_is1'
$MinVersion = [version]'4.5.0'

try {
    $key = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$AppId" -ErrorAction SilentlyContinue
    if (-not $key) {
        Write-Output 'Melissa not installed.'
        exit 1
    }
    $exe = Join-Path $key.InstallLocation 'Melissa.exe'
    if (-not (Test-Path $exe)) {
        Write-Output "Melissa.exe missing: $exe"
        exit 1
    }
    if ([version]$key.DisplayVersion -lt $MinVersion) {
        Write-Output "Melissa $($key.DisplayVersion) is older than $MinVersion."
        exit 1
    }
    Write-Output "Melissa $($key.DisplayVersion) installed."
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
