<#
.SYNOPSIS
    Intune Remediation: install the latest Visual C++ 2015-2022 x64 runtime.
.DESCRIPTION
    Downloads Microsoft's permalink installer, refuses to run it unless the
    Authenticode signature is valid and issued to Microsoft Corporation, then
    installs silently without restarting. Run as SYSTEM, 64-bit.
#>
$ErrorActionPreference = 'Stop'
$Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
$Installer = Join-Path $env:TEMP 'vc_redist.x64.exe'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing

    $sig = Get-AuthenticodeSignature -FilePath $Installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Untrusted installer signature: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }

    $p = Start-Process -FilePath $Installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    # 0 = success, 1638 = newer version already installed, 3010 = restart required.
    if ($p.ExitCode -notin 0, 1638, 3010) {
        throw "Installer exit code $($p.ExitCode)"
    }
    Write-Output "VC++ x64 runtime installer exit code $($p.ExitCode)."
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item -Path $Installer -Force -ErrorAction SilentlyContinue
}
