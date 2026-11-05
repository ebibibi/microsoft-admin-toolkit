<#
.SYNOPSIS
    Intune Remediation: install KeePassXC or update it to the newest eligible upstream release.
.DESCRIPTION
    Downloads the MSI from the upstream GitHub release into a folder only SYSTEM and
    Administrators can write, then checks the SHA-256 digest and the Authenticode
    signer. If KeePassXC or its browser proxy is running the app is never closed:
    a one-shot startup task installs the checked MSI at the next restart. An hourly
    run also installs it as soon as the app happens to be closed.
    Run as SYSTEM, 64-bit PowerShell.
    Keep $MinReleaseAgeDays and the shared functions identical in Detect.ps1.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleasesApi = 'https://api.github.com/repos/keepassxreboot/keepassxc/releases?per_page=10'
$MinReleaseAgeDays = 3
$ExpectedSigner = 'DroidMonkey Apps, LLC'
$ProcessNames = @('KeePassXC', 'keepassxc-proxy', 'keepassxc-cli')
$WorkDir = Join-Path $env:ProgramData 'KeePassXCUpdate'
$TaskName = 'KeePassXCUpdate-AtStartup'

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

function Assert-VcRuntime {
    # The KeePassXC MSI does not bundle these; without them the app silently fails to start.
    $missing = 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll' |
        Where-Object { -not (Test-Path (Join-Path $env:SystemRoot "System32\$_")) }
    if ($missing) { throw "Visual C++ runtime missing ($($missing -join ', ')). Deploy it first; the next run retries." }
}

function Initialize-WorkDir {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    # ProgramData lets users create files, and the MSI later runs as SYSTEM.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $WorkDir -AclObject $acl
}

function Test-Msi {
    param([string]$Path, [string]$Sha256)
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256) { throw "SHA-256 mismatch for $Path" }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch [regex]::Escape($ExpectedSigner)) {
        throw "Signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
}

function Get-CheckedMsi {
    param($Target)
    Initialize-WorkDir
    $msi = Join-Path $WorkDir $Target.Name
    Get-ChildItem -Path $WorkDir -Filter '*.msi' | Where-Object { $_.FullName -ne $msi } | Remove-Item -Force
    if (Test-Path $msi) {
        try { Test-Msi -Path $msi -Sha256 $Target.Sha256; return $msi }
        catch { Remove-Item $msi -Force }
    }
    Invoke-WebRequest -Uri $Target.Url -OutFile $msi -UseBasicParsing -TimeoutSec 600
    Test-Msi -Path $msi -Sha256 $Target.Sha256
    return $msi
}

function Register-StartupInstall {
    param([string]$Msi)
    # The task removes itself and the MSI; a failed install is retried by the hourly run.
    $command = "/c start /wait `"`" msiexec.exe /i `"$Msi`" /qn /norestart & " +
        "schtasks.exe /Delete /TN $TaskName /F & del /q `"$Msi`""
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $command
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Remove-StartupInstall {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 60
    $target = Select-TargetRelease -Releases $releases -Arch $env:PROCESSOR_ARCHITECTURE `
        -Now (Get-Date) -MinAgeDays $MinReleaseAgeDays
    if (-not $target) { throw 'No eligible KeePassXC release found.' }
    $installed = Get-InstalledVersion
    if ($installed -and $installed -ge $target.Version) {
        Remove-StartupInstall
        Write-Output "KeePassXC $installed is already current."
        exit 0
    }
    Assert-VcRuntime
    $msi = Get-CheckedMsi -Target $target
    if (Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue) {
        Register-StartupInstall -Msi $msi
        Write-Output "KeePassXC is open: $($target.Version) is checked and will install at the next restart."
        exit 0
    }
    Remove-StartupInstall
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit code $($p.ExitCode)" }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    Write-Output "KeePassXC $installed -> $($target.Version) (msiexec $($p.ExitCode))."
    exit 0
}
catch { Write-Output "Remediation error: $($_.Exception.Message)"; exit 1 }
