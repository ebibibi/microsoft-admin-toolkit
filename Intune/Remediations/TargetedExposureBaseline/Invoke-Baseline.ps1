<#
.SYNOPSIS
Apply a small, reversible exposure baseline to one explicitly named computer.
.DESCRIPTION
No software removal, process termination, reboot, or authentication changes.
Invoke in 64-bit Windows PowerShell as SYSTEM through Intune Remediations.
Embed the required target name in a private deployment payload; never assign
the package to all devices. Intune detection uses Mode Detect (exit 1 if drift).
#>
param(
    [Parameter(Mandatory = $true)][string]$ExpectedComputerName,
    [ValidateSet('Detect', 'Remediate')][string]$Mode = 'Detect'
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExpectedComputerName) -or
    $env:COMPUTERNAME -ine $ExpectedComputerName) {
    Write-Output 'Target guard failed; no changes made.'
    exit 1
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitProcess) {
    Write-Output '64-bit Windows PowerShell is required.'
    exit 1
}

$settings = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connections'; Name = 'NC_StdDomainUserSetLocation'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\COM Compatibility\{D27CDB6E-AE6D-11CF-96B8-444553540000}'; Name = 'activationfilteroverride'; Value = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\COM Compatibility\{D27CDB70-AE6D-11CF-96B8-444553540000}'; Name = 'activationfilteroverride'; Value = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'enableautomaticupdates'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'hideenabledisableupdates'; Value = 1 }
)
$dir = Join-Path $env:ProgramData 'TargetedExposureBaseline'
$backupFile = Join-Path $dir 'original-values.json'
try {
    $drift = @()
    $original = @()
    foreach ($s in $settings) {
        $item = Get-ItemProperty -LiteralPath $s.Path -ErrorAction SilentlyContinue
        $prop = if ($null -ne $item) { $item.PSObject.Properties[$s.Name] } else { $null }
        $exists = $null -ne $prop
        $kind = if ($exists) { (Get-Item -LiteralPath $s.Path).GetValueKind($s.Name).ToString() } else { $null }
        $original += @{ Path = $s.Path; Name = $s.Name; Exists = $exists; Value = $(if ($exists) { $prop.Value } else { $null }); Kind = $kind }
        if (-not $exists -or $prop.Value -ne $s.Value -or $kind -ne 'DWord') { $drift += $s }
    }
    if ($Mode -eq 'Detect') {
        # Inventory only: do not invoke installers or load other users' hives.
        $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        $apps = @(Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Azure CLI|Docker Desktop|DaVinci Resolve|Git$|PowerShell|VLC|Python' } |
            ForEach-Object { "$($_.DisplayName)=$($_.DisplayVersion)" } | Sort-Object -Unique)
        $busy = @(Get-Process -Name Resolve,Obsidian,'Docker Desktop',vlc -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ProcessName -Unique)
        $winget = @(Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe' -ErrorAction SilentlyContinue)
        Write-Output ("baselineDrift=$($drift.Count); apps=" + ($apps -join ',') + '; busy=' + ($busy -join ',') + "; wingetFound=$($winget.Count -gt 0); PS=$($PSVersionTable.PSVersion)")
        if ($drift.Count -gt 0) { exit 1 }
        exit 0
    }
    if ($drift.Count -eq 0) { Write-Output 'Baseline already compliant.'; exit 0 }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Keep the first backup across retries; never overwrite the original values.
    if (-not (Test-Path -LiteralPath $backupFile)) {
        $original | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupFile -Encoding UTF8
    }
    $verifiedBackup = @(Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json)
    if ($verifiedBackup.Count -ne $settings.Count) { throw 'Original-value backup is incomplete.' }
    foreach ($s in $drift) {
        New-Item -Path $s.Path -Force | Out-Null
        New-ItemProperty -LiteralPath $s.Path -Name $s.Name -PropertyType DWord -Value $s.Value -Force | Out-Null
        $actual = Get-ItemPropertyValue -LiteralPath $s.Path -Name $s.Name
        if ($actual -ne $s.Value) { throw "Readback failed for $($s.Name)" }
    }
    Write-Output "Applied $($drift.Count) registry values; original values saved to $backupFile; no restart requested."
    exit 0
}
catch {
    Write-Output "Baseline failed: $($_.Exception.Message)"
    exit 1
}
