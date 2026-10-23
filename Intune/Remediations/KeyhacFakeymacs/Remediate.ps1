<#
.SYNOPSIS
    Intune Remediation: install Keyhac + Fakeymacs for the signed-in user.
.DESCRIPTION
    1. If keyhac.exe is missing, download the pinned Keyhac release and verify
       its SHA-256. Nothing is taken from user-synced storage such as the
       personal OneDrive, so every device gets the same, reviewed binaries.
    2. If config.py is not Fakeymacs, back it up and add Fakeymacs from the
       pinned upstream commit.
    3. Make config_personal.py use the Right Ctrl key (fc.side_of_ctrl_key).
       Pair with the KeyboardScancodeSwap remediation so CapsLock sends Right Ctrl.
    4. Create a Startup shortcut and (re)start Keyhac.
    Run as the logged-on user (runAsAccount = user), 64-bit PowerShell.
#>
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Keyhac'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Keyhac.lnk'
$CtrlSide = 'R'

$KeyhacZipUrl = 'https://github.com/crftwr/keyhac-win/releases/download/v1.83/keyhac_183.zip'
$KeyhacZipSha256 = 'A54A7332D51579EDFCAB1DC64AB1C559DC07141971198A154B3C179716897267'
$FakeymacsCommit = 'f83de826fc7a2ac76a0d5f91f2b54a3f0a50d1e4'
$FakeymacsZipUrl = "https://codeload.github.com/smzht/fakeymacs/zip/$FakeymacsCommit"
$FakeymacsItems = @('config.py', 'keyhac.bat', '_config_personal.py', '_config_parameter.py', 'fakeymacs_extensions')

$log = New-Object System.Collections.Generic.List[string]
$tempDirs = New-Object System.Collections.Generic.List[string]

function Stop-Keyhac {
    Get-Process -Name keyhac -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force
}

function Copy-Folder {
    param([string]$Source, [string]$Destination)
    & robocopy.exe $Source $Destination /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD '__pycache__' | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $Source" }
}

function Expand-Download {
    param([string]$Url, [string]$Sha256, [string]$Name)
    $work = Join-Path $env:TEMP ("keyhac-setup-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $tempDirs.Add($work)
    $zip = Join-Path $work "$Name.zip"
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
    if ($Sha256) {
        $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { throw "$Name hash mismatch: $actual" }
    }
    $out = Join-Path $work 'x'
    Expand-Archive -Path $zip -DestinationPath $out
    # Both archives contain a single top-level folder.
    return (Get-ChildItem -Path $out -Directory | Select-Object -First 1).FullName
}

function Set-CtrlSide {
    param([string]$Path, [string]$Side)
    $text = [IO.File]::ReadAllText($Path)
    $line = 'fc.side_of_ctrl_key = "' + $Side + '"'
    $assign = '(?m)^fc\.side_of_ctrl_key\s*=\s*"[^"]*"'
    if ([regex]::IsMatch($text, $assign)) {
        $new = [regex]::Replace($text, $assign, $line)
    }
    else {
        $header = [regex]::Match($text, '(?m)^# \[section-base-1\][^\r\n]*\r?\n')
        if ($header.Success) {
            $new = $text.Insert($header.Index + $header.Length, "$line`n")
        }
        else {
            $new = $text.TrimEnd() + "`n`n# [section-base-1] ---`n$line`n"
        }
    }
    if ($new -eq $text) { return $false }
    [IO.File]::WriteAllText($Path, $new, (New-Object Text.UTF8Encoding $false))
    return $true
}

function New-StartupShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartupLink)
    # keyhac.bat (from Fakeymacs) starts keyhac.exe with HIGH priority.
    $lnk.TargetPath = Join-Path $InstallDir 'keyhac.bat'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation = (Join-Path $InstallDir 'keyhac.exe') + ',0'
    $lnk.WindowStyle = 7
    $lnk.Save()
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $restart = $false

    if (-not (Test-Path (Join-Path $InstallDir 'keyhac.exe'))) {
        $dir = Expand-Download -Url $KeyhacZipUrl -Sha256 $KeyhacZipSha256 -Name 'keyhac'
        Copy-Folder -Source $dir -Destination $InstallDir
        $log.Add('installed Keyhac 1.83 from GitHub')
        $restart = $true
    }

    $config = Join-Path $InstallDir 'config.py'
    if (-not (Test-Path $config) -or -not (Select-String -Path $config -Pattern '^fakeymacs_version' -Quiet)) {
        Stop-Keyhac
        if (Test-Path $config) {
            Copy-Item -Path $config -Destination ("$config.bak-" + (Get-Date -Format 'yyyyMMddHHmmss'))
        }
        $dir = Expand-Download -Url $FakeymacsZipUrl -Sha256 $null -Name 'fakeymacs'
        foreach ($item in $FakeymacsItems) {
            Copy-Item -Path (Join-Path $dir $item) -Destination $InstallDir -Recurse -Force
        }
        $log.Add("installed Fakeymacs $($FakeymacsCommit.Substring(0, 8))")
        $restart = $true
    }

    $personal = Join-Path $InstallDir 'config_personal.py'
    if (-not (Test-Path $personal)) {
        $sample = Join-Path $InstallDir '_config_personal.py'
        if (Test-Path $sample) { Copy-Item -Path $sample -Destination $personal }
        else { [IO.File]::WriteAllText($personal, "# [section-base-1] ---`n") }
        $log.Add('created config_personal.py')
    }
    if (Set-CtrlSide -Path $personal -Side $CtrlSide) {
        $log.Add("set side_of_ctrl_key = $CtrlSide")
        $restart = $true
    }

    if (-not (Test-Path $StartupLink)) {
        New-StartupShortcut
        $log.Add('created Startup shortcut')
    }

    $running = Get-Process -Name keyhac -ErrorAction SilentlyContinue
    if ($restart -or -not $running) {
        Stop-Keyhac
        Start-Process -FilePath (Join-Path $InstallDir 'keyhac.bat') -WorkingDirectory $InstallDir -WindowStyle Hidden
        $log.Add('started Keyhac')
    }

    Write-Output ('Keyhac remediation: ' + ($log -join '; '))
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message) [done: $($log -join '; ')]"
    exit 1
}
finally {
    foreach ($d in $tempDirs) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
}
