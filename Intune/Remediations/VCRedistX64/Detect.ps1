<#
.SYNOPSIS
    Intune Remediation detection: is the Visual C++ 2015-2022 x64 runtime installed?
.DESCRIPTION
    Keyhac for Windows 1.83 (x64) needs this runtime. Run as SYSTEM, 64-bit.
#>
$ErrorActionPreference = 'Stop'
$KeyPath = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'

try {
    $rt = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue
    if ($rt -and $rt.Installed -eq 1) {
        Write-Output "VC++ x64 runtime installed: $($rt.Version)"
        exit 0
    }
    Write-Output 'VC++ x64 runtime not installed.'
    exit 1
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
