<#
.SYNOPSIS
    Intune Remediation: copy portable tools from the user's personal OneDrive.
.DESCRIPTION
    For each tool, find the newest folder under the personal OneDrive
    (OneDriveConsumer) that contains one of its executables - first under
    $PreferredRoot, then the whole OneDrive up to $MaxDepth folders deep - copy
    it to %LOCALAPPDATA%\Programs\<Name>, and add a Start menu shortcut.
    Password databases (*.kdbx) are never copied: keep opening them from
    OneDrive so there is one synced copy.
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
#>
$ErrorActionPreference = 'Stop'

$Tools = @(
    @{ Name = 'KeePass'; Executables = @('KeePass.exe', 'KeePassXC.exe') }
)
$ProgramsDir = Join-Path $env:LOCALAPPDATA 'Programs'
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Portable'
$PreferredRoot = 'settings'
$MaxDepth = 3

function Find-ToolFolder {
    param([string]$OneDrive, [string[]]$Executables)
    $roots = @((Join-Path $OneDrive $PreferredRoot), $OneDrive) | Where-Object { Test-Path $_ }
    foreach ($root in $roots) {
        $hit = foreach ($name in $Executables) {
            Get-ChildItem -Path $root -Filter $name -File -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue
        }
        $best = $hit | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($best) { return $best }
    }
    return $null
}

try {
    $oneDrive = $env:OneDriveConsumer
    if (-not $oneDrive -or -not (Test-Path $oneDrive)) {
        throw 'Personal OneDrive is not signed in on this device (OneDriveConsumer not set).'
    }

    New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null
    $done = @()
    $notFound = @()
    foreach ($tool in $Tools) {
        $exe = Find-ToolFolder -OneDrive $oneDrive -Executables $tool.Executables
        if (-not $exe) { $notFound += $tool.Name; continue }

        $dest = Join-Path $ProgramsDir $tool.Name
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($dest, [StringComparison]::OrdinalIgnoreCase) } |
            Stop-Process -Force
        & robocopy.exe $exe.DirectoryName $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF '*.kdbx' '*.kdbx.*' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) for $($tool.Name)" }

        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $StartMenuDir "$($tool.Name).lnk"))
        $lnk.TargetPath = Join-Path $dest $exe.Name
        $lnk.WorkingDirectory = $dest
        $lnk.Save()
        $done += $tool.Name
    }

    if ($notFound.Count -gt 0) {
        Write-Output ("Copied: $($done -join ', '). Not found in OneDrive: " + ($notFound -join ', '))
        exit 1
    }
    Write-Output "Copied: $($done -join ', ')"
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
