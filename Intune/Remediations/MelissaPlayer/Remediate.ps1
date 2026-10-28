<#
.SYNOPSIS
    Intune Remediation: install Melissa (music practice player) for all users.
.DESCRIPTION
    Downloads the pinned upstream release of https://github.com/mosynthkey/Melissa,
    checks the SHA-256 of the zip and of the installer inside it (the Inno Setup
    installer is not Authenticode-signed), then installs it silently into
    Program Files. The installer also installs the VC++ x64 runtime.
    Skips the run while Melissa is open so an upgrade never closes it mid-practice.
    Run as SYSTEM, 64-bit. To upgrade, update the constants here and
    $MinVersion in Detect.ps1.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Version = '4.5.0'
$ZipUrl = "https://github.com/mosynthkey/Melissa/releases/download/v$Version/Melissa_${Version}_64.zip"
$ZipSha256 = '831C07081E97B9BBD90C17D3FA8E74962618015A0CB99EA856271EBBC4890041'
$InstallerName = "Melissa_Installer_v$Version.exe"
$InstallerSha256 = 'FDB2A15404B46110A9F3D033D7CB740281192D75B35358DC1B1ABC1D22EA65E5'
$WorkDir = Join-Path $env:TEMP 'MelissaSetup'

function Assert-Sha256 {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "SHA-256 mismatch for $(Split-Path $Path -Leaf): $actual"
    }
}

try {
    if (Get-Process -Name 'Melissa' -ErrorAction SilentlyContinue) {
        Write-Output 'Melissa is running; install postponed to the next run.'
        exit 1
    }

    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    $zip = Join-Path $WorkDir 'Melissa.zip'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    Assert-Sha256 -Path $zip -Expected $ZipSha256

    Expand-Archive -Path $zip -DestinationPath $WorkDir -Force
    $installer = Join-Path $WorkDir $InstallerName
    Assert-Sha256 -Path $installer -Expected $InstallerSha256

    $setupArgs = '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/LANG=japanese'
    $p = Start-Process -FilePath $installer -ArgumentList $setupArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "Installer exit code $($p.ExitCode)"
    }
    Write-Output "Melissa $Version installed."
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
