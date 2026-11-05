### SYSTEMの保存資格情報を確認する部品（Windows PowerShell 5.1 / 管理者として実行）
### DC宛の「ドメインの資格情報」がSYSTEMにあると、SYSTEMの処理がそのユーザーとしてDCへ接続する。
### 確認は読み取りだけ。削除は Remove-SystemSavedCredential を呼んだときだけ行う。

function Invoke-CmdkeyAsSystem {
    param(
        [Parameter(Mandatory)][string]$CmdkeyArguments,
        [int]$TimeoutSec = 30
    )
    $taskName = "MEHJ-Cmdkey-" + [guid]::NewGuid().ToString("N")
    $outFile  = Join-Path $env:windir "Temp\$taskName.txt"
    $cmdkey   = Join-Path $env:windir "System32\cmdkey.exe"
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:windir "System32\cmd.exe") `
        -Argument ('/d /c ""{0}" {1} > "{2}" 2>&1"' -f $cmdkey, $CmdkeyArguments, $outFile)
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    # 既定のままだとノートPCのバッテリー駆動中はタスクが起動しない
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # schtasks /Run や Start-ScheduledTask の成功は「起動を依頼できた」だけ。結果は LastTaskResult で見る
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Milliseconds 500
            $result = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop).LastTaskResult
            $state  = (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
            $done   = ($state -eq "Ready") -and ($result -ne 267011) -and ($result -ne 267009)  # 未実行 / 実行中
        } until ($done -or (Get-Date) -gt $deadline)

        if (-not $done) { throw "SYSTEMのタスクが $TimeoutSec 秒以内に終わりませんでした（状態: $state）" }
        if (-not (Test-Path -LiteralPath $outFile)) { throw "SYSTEMのタスクの出力がありません（結果コード: $result）" }

        # cmdkey の出力はOEMコードページ（日本語版は932）
        $oemCp = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage").OEMCP
        $text  = [Text.Encoding]::GetEncoding([int]$oemCp).GetString([IO.File]::ReadAllBytes($outFile))
        [pscustomobject]@{ ExitCode = $result; Output = $text }
    }
    finally {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
        catch { Write-Warning "一時タスク $taskName を削除できませんでした: $($_.Exception.Message)" }
    }
}

function Get-DomainTargetName {
    # 資格情報の宛先と照合する名前: ドメイン名（DNS / NetBIOS）、全DCのFQDN・短い名前・IPアドレス
    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $domain = [DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()   # 取れなければ例外（判定不能として扱う）
    [void]$names.Add($domain.Name)
    [void]$names.Add("*.$($domain.Name)")
    $netbios = (Get-CimInstance Win32_NTDomain -ErrorAction SilentlyContinue |
        Where-Object { $_.DnsForestName -and $_.DomainName } | Select-Object -First 1).DomainName
    if ($netbios) { [void]$names.Add($netbios) }
    foreach ($dc in $domain.DomainControllers) {
        [void]$names.Add($dc.Name)
        [void]$names.Add(($dc.Name -split "\.")[0])
        if ($dc.IPAddress) { [void]$names.Add($dc.IPAddress) }
    }
    ,$names
}

function Test-TargetMatchesDc {
    param([string]$Target, $DomainNames)
    if ($DomainNames.Contains($Target)) { return $true }
    if ($Target -notmatch "\*") { return $false }
    # ワイルドカードの宛先（*、*.example.com、DOMAIN\*）
    if ($Target -match "\\\*$") { return $DomainNames.Contains(($Target -split "\\")[0]) }
    foreach ($name in $DomainNames) {
        if ($name -notmatch "\*" -and $name -like $Target) { return $true }
    }
    return $false
}

function Get-SystemSavedCredential {
    $r = Invoke-CmdkeyAsSystem -CmdkeyArguments "/list"
    if ($r.ExitCode -ne 0) { throw "SYSTEMでのcmdkey /listが失敗しました（結果コード: $($r.ExitCode)）: $($r.Output)" }
    if ([string]::IsNullOrWhiteSpace($r.Output)) { throw "SYSTEMでのcmdkey /listの出力が空です" }
    $domainNames = Get-DomainTargetName

    $current = $null
    foreach ($line in ($r.Output -split "\r?\n")) {
        # 表示名は言語で変わるが、Domain:target=〜 の部分は変わらない
        if ($line -match "^\s*\S+\s*:\s*(?<scheme>[^:=\s]+):target=(?<target>\S.*?)\s*$") {
            if ($current) { [pscustomobject]$current }
            $target = $Matches.target
            $current = [ordered]@{
                FullTarget = "$($Matches.scheme):target=$target"
                User       = ""
                # 接続に自動で使われるのはドメインの資格情報（Domain:target=〜）だけ
                PointsToDc = ($Matches.scheme -eq "Domain") -and (Test-TargetMatchesDc $target $domainNames)
            }
        }
        elseif ($current -and $line -match "^\s*(ユーザー|User)\s*:\s*(?<user>\S.*?)\s*$") {
            $current.User = $Matches.user
        }
    }
    if ($current) { [pscustomobject]$current }
}

function Remove-SystemSavedCredential {
    param([Parameter(Mandatory)][string]$FullTarget)
    # SYSTEMのコマンド行に入るので、想定外の文字は通さない
    if ($FullTarget -notmatch '^[A-Za-z]+:target=[\w\.\-\*\\:]+$') { throw "想定外の宛先です: $FullTarget" }
    $r = Invoke-CmdkeyAsSystem -CmdkeyArguments "/delete:$FullTarget"
    if ($r.ExitCode -ne 0) { throw "削除に失敗しました（結果コード: $($r.ExitCode)）: $($r.Output)" }
    if (Get-SystemSavedCredential | Where-Object FullTarget -eq $FullTarget) { throw "削除後も残っています: $FullTarget" }
}
